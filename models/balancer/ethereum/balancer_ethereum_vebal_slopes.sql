{{
    config(
        alias='vebal_slopes',
        partition_by = ['block_date'],
        materialized = 'incremental',
        file_format = 'delta',
        incremental_strategy = 'merge',
        unique_key = ['block_number', 'wallet_address'],
        post_hook='{{ expose_spells(\'["ethereum"]\',
                                    "project",
                                    "balancer",
                                    \'["markusbkoch", "mendesfabio", "stefenon"]\') }}'
    )
}}


WITH base_locks AS (
        SELECT d.provider, ts AS locked_at, locktime AS unlocked_at, ts AS updated_at
        FROM {{ source('balancer_ethereum', 'veBAL_call_create_lock') }} l
        JOIN {{ source('balancer_ethereum', 'veBAL_evt_Deposit') }} d
        ON d.evt_tx_hash = l.call_tx_hash
        {% if is_incremental() %}
        WHERE d.evt_block_time >= DATE_TRUNC('day', NOW() - interval '1 week')
        AND l.call_block_time >= DATE_TRUNC('day', NOW() - interval '1 week')
        {% endif %}

        UNION ALL

        SELECT provider, cast(null as numeric(38)) AS locked_at, locktime AS unlocked_at, ts AS updated_at
        FROM {{ source('balancer_ethereum', 'veBAL_evt_Deposit') }}
        WHERE value = 0
        {% if is_incremental() %}
        AND evt_block_time >= DATE_TRUNC('day', NOW() - interval '1 week')
        {% endif %}
    ),

    decorated_locks AS (
        SELECT provider,
               unlocked_at,
               updated_at,
               FIRST_VALUE(locked_at) OVER (PARTITION BY provider, locked_partition ORDER BY updated_at) AS locked_at
        FROM (SELECT *,
                     SUM(CASE WHEN locked_at IS NULL THEN 0 ELSE 1 END)
                         OVER (PARTITION BY provider ORDER BY updated_at) AS locked_partition
              FROM base_locks) AS foo
    ),

    locks_info AS (
        SELECT *, unlocked_at - locked_at AS lock_period
        FROM decorated_locks
    ),

    deposits AS (
        SELECT
            provider,
            evt_block_number AS block_number,
            evt_block_time AS block_time,
            SUM(value/1e18) AS delta_bpt
        FROM {{ source('balancer_ethereum', 'veBAL_evt_Deposit') }}
        {% if is_incremental() %}
        WHERE evt_block_time >= DATE_TRUNC('day', NOW() - interval '1 week')
        {% endif %}
        GROUP BY provider, block_number, block_time
    ),

    withdrawals AS (
        SELECT
            provider,
            evt_block_number AS block_number,
            evt_block_time AS block_time,
            -SUM(value/1e18) AS delta_bpt
        FROM {{ source('balancer_ethereum', 'veBAL_evt_Withdraw') }}
        {% if is_incremental() %}
        WHERE evt_block_time >= DATE_TRUNC('day', NOW() - interval '1 week')
        {% endif %}
        GROUP BY provider, block_number, block_time
    ),

    bpt_locked_balance AS (
        SELECT block_number, block_time, provider, SUM(delta_bpt) AS bpt_balance
        FROM (
            SELECT * FROM deposits
            UNION ALL
            SELECT * FROM withdrawals
        ) union_all
        GROUP BY provider, block_number, block_time
    ),

    cumulative_balances AS (
        SELECT
            block_number,
            block_time,
            provider,
            SUM(bpt_balance) OVER (
                PARTITION BY provider
                ORDER BY block_number
                ROWS BETWEEN
                UNBOUNDED PRECEDING AND
                CURRENT ROW
            ) AS bpt_balance
        FROM bpt_locked_balance b
    ),

    double_counting AS (
        SELECT
            block_number,
            block_time,
            updated_at,
            unix_timestamp(block_time) AS block_timestamp,
            b.provider AS wallet_address,
            bpt_balance,
            unlocked_at,
            bpt_balance / (365*86400) AS slope,
            (unlocked_at - unix_timestamp(block_time)) * bpt_balance / (365*86400) AS bias
        FROM cumulative_balances b
        LEFT JOIN locks_info l
        ON l.provider = b.provider
        AND l.updated_at <= unix_timestamp(block_time)
    ),

    max_updated_at AS (
        SELECT
            block_number,
            block_time,
            wallet_address,
            max(updated_at) AS updated_at
        FROM double_counting
        GROUP BY block_number, block_time, wallet_address
    )

SELECT
    a.block_number,
    a.block_time,
    a.block_timestamp,
    a.wallet_address,
    a.bpt_balance,
    a.unlocked_at,
    a.slope,
    a.bias,
    date_trunc('day', a.block_time) as block_date
FROM double_counting a
INNER JOIN max_updated_at b
ON a.block_number = b.block_number
AND a.block_time = b.block_time
AND a.wallet_address = b.wallet_address
AND a.updated_at = b.updated_at
ORDER BY a.wallet_address, a.block_number
