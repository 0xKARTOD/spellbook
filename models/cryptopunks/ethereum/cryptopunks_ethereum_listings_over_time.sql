{{ config(
        alias ='listings_over_time',
        unique_key='day',
        post_hook='{{ expose_spells_hide_trino(\'["ethereum"]\',
                                    "project",
                                    "cryptopunks",
                                    \'["cat"]\') }}'
        )
}}

with all_listing_events as (
    select  punk_id
            , event_type
            , case  when event_type = 'Offered' and to is null then 'Public Listing'
                    when event_type = 'Offered' and to is not null then 'Private Listing'
                else 'Listing Withdrawn' end as event_sub_type
            , eth_amount as listed_price
            , to as listing_offered_to
            , evt_block_number
            , evt_index
            , evt_block_time
            , evt_tx_hash
    from {{ ref('cryptopunks_ethereum_punk_offer_events') }}
)
, all_buys as (
    select  token_id as punk_id
            , 'Punk Bought' as event_type
            , 'Punk Bought' as event_sub_type
            , cast(NULL as double) as listed_price
            , cast(NULL as varchar(5)) as listing_offered_to
            , block_number as evt_block_number
            , evt_index
            , block_time as evt_block_time
            , tx_hash as evt_tx_hash
    from {{ ref('cryptopunks_ethereum_trades') }}
)
, all_transfers as (
    select  punk_id
            , 'Punk Transfer' as event_type
            , 'Punk Transfer' as event_sub_type
            , cast(NULL as double) as listed_price
            , cast(NULL as varchar(5)) as listing_offered_to
            , evt_block_number
            , evt_index
            , evt_block_time
            , evt_tx_hash
    from {{ ref('cryptopunks_ethereum_punk_transfers') }}
)
, base_data as (
    with all_days  as (select explode(sequence(to_date('2017-06-23'), to_date(now()), interval 1 day)) as day)
    , all_punk_ids as (select explode(sequence(0, 9999, 1)) as punk_id)
    
    select  day
            , punk_id
    from all_days
    full outer join all_punk_ids on true
)
, all_punk_events as (
    select *
          , row_number() over (partition by punk_id order by evt_block_number asc, evt_index asc ) as punk_event_index
    from 
    (   select * from all_listing_events
        union all select * from all_buys
        union all select * from all_transfers
    ) a 
)
, aggregated_punk_on_off_data as (
    select date_trunc('day',a.evt_block_time) as day 
            , a.punk_id 
            , case when event_type = 'Offered' then 'Active' else 'Not Listed' end as listed_bool
    from all_punk_events a 
    inner join (    select date_trunc('day', evt_block_time) as day 
                            , punk_id
                            , max(punk_event_index) as max_event
                    from all_punk_events
                    group by 1,2
                ) b -- max event per punk per day 
    on date_trunc('day',a.evt_block_time) = b.day and a.punk_id = b.punk_id and a.punk_event_index = b.max_event
)
select day 
        , sum(case when bool_fill_in = 'Active' then 1 else 0 end) as listed_count
from 
(   select c.*
            , last_value(listed_bool,true) over (partition by punk_id order by day asc) as bool_fill_in
    from 
    (   select a.day
                , a.punk_id 
                , listed_bool 
        from base_data a
        left outer join aggregated_punk_on_off_data b 
        on a.day = b.day and a.punk_id = b.punk_id
    ) c 
) d 
group by 1 
order by day desc 