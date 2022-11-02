address HoustonCoin{

    module coin{

        use std::string;
        use std::signer;
        use std::option;
        use std::vector;
    

        use aptos_framework::event::{Self, EventHandle};
        use aptos_framework::coin;
        use aptos_framework::timestamp;
        use aptos_framework::account;

        struct HOU {}

        const COIN_NAME: vector<u8> = b"Houston Token";
        const COIN_SYMBOL: vector<u8> = b"HOU";
        const DECIMAL: u8 = 8;

        // 1_000_000_000 * 1e8
        const MAX_SUPPLY_CAP: u64 = 1000000000 * 100000000;

        const ERROR_NOT_OWNER: u64 = 1;
        const ERROR_MAX_OUT: u64 = 2;
        // const ERROR_MAX_ALREADY_SET: u64 = 3;
        const ERROR_SUPPLY_INFO: u64 = 4;
        const ERROR_PENDING_AMT_NOT_ENOUGH: u64 = 5;
        const ERROR_ALLOCATION_ALREADY_INIT: u64 = 6;
        const ERROR_NO_EVENTS_RESOURCES: u64 = 7;


        const ONE_MONTH: u64 = 60*60*24*365 / 12;

        const PRECISION: u128 = 1000000000000;

        struct Caps<phantom CoinType> has key {
            mint: aptos_framework::coin::MintCapability<CoinType>,
            freeze: aptos_framework::coin::FreezeCapability<CoinType>,
            burn: aptos_framework::coin::BurnCapability<CoinType>,
        }

        /// Capability: ability to harvest the pending coins
        struct MiningCapability has copy, store {}
        /// Capability: ability to burn HOU coins
        struct BurningCapability has copy, store {}
        

        #[method(
            pending_supply_info
        )]
        struct SupplyInfo has key {
            max: u64,
            supply_per_sec: u64,
            acc_supply: u64,
            last_supply_ts: u64,
        }

        struct Allocation has store {
            max: u64,
            minted: u64,
            tge_mint: u64,

            cliff_amount: u64,
            cliff_start: u64,
            cliff_period: u64,

            vesting_amount: u64,
            vesting_start: u64,
            vesting_period: u64,
        }

        #[method(
            pending_claim
        )]
        struct AllocationStore has key {
            pools: vector<Allocation>,
        }

        struct Events has key {
            vesting_events: EventHandle<VestingEvent>,
            manual_burn_events: EventHandle<ManualBurnEvent>
        }

        struct VestingEvent has store, drop {
            poolId: u64,
            amount: u64,
            to: address
        }

        struct ManualBurnEvent has store, drop {
            amount: u64
        }


        fun init_module(creator: &signer) {
            initialize_coin(creator);
        }

        /// Initialize HOU coin to coin module
        fun initialize_coin(creator: &signer) {
            // Init coin info with aptos coin module
            if(!exists<Caps<HOU>>(signer::address_of(creator))){
                // init the coin
                let (
                    burn_cap,
                    freeze_cap,
                    mint_cap
                ) = coin::initialize<HOU>(creator, string::utf8(COIN_NAME), string::utf8(COIN_SYMBOL), DECIMAL, true);

                move_to(creator, Caps<HOU> { mint: mint_cap, freeze: freeze_cap, burn: burn_cap });
            };

            if(!exists<Events>(signer::address_of(creator))){
                // init event handle
                move_to(creator, Events{
                        vesting_events: account::new_event_handle<VestingEvent>(creator),
                        manual_burn_events: account::new_event_handle<ManualBurnEvent>(creator),
                    }
                );
            };
        }


        public entry fun initialize_all_vesting(signer: &signer){
            initialize_mining(signer);
            initialize_allocation(signer);
        }


        /// Init coin mining pool
        public fun initialize_mining(signer: &signer) {
            assert_admin(signer);

            // 450_000_000 * 1e8
            let miningCap : u64 = 450000000 * 100000000;
            let supplyPerSec: u64 = miningCap / (60*60*24*365*3); // 3 year
            let start_time = timestamp::now_seconds();

            if(!exists<SupplyInfo>(signer::address_of(signer))) {
                move_to(signer, SupplyInfo{
                    max: miningCap,
                    supply_per_sec: supplyPerSec,
                    acc_supply: 0,
                    last_supply_ts: start_time,
                });
            };
        }


        public fun initialize_allocation(
            signer: &signer
        ){
            assert_admin(signer);
            assert!(!exists<AllocationStore>(signer::address_of(signer)), ERROR_ALLOCATION_ALREADY_INIT);

            let now = timestamp::now_seconds();
            let pools = vector::empty();

            let ecosystem   = 260000000 * 100000000;
            let team        = 250000000 * 100000000;
            let advisor     = 20000000 * 100000000;
            let launchpad   = 20000000 * 100000000;

            // Partnership & Ecosystem
            vector::push_back(&mut pools, Allocation{
                max: ecosystem,
                minted: 0,
                tge_mint: ecosystem * 5 / 100, //5%
                cliff_amount: 0,
                cliff_start: 0,
                cliff_period: 0,

                vesting_amount: ecosystem - (ecosystem * 5 / 100), // 100 - 5%
                vesting_start: now,
                vesting_period: 24 * ONE_MONTH,
            });

            // Team
            vector::push_back(&mut pools, Allocation{
                max: team,
                minted: 0,
                tge_mint: 0,
                cliff_amount: team / 10, // 10%
                cliff_start: now,
                cliff_period: 6 * ONE_MONTH,

                vesting_amount: team - (team / 10), //100% - 10%
                vesting_start: now + (6 * ONE_MONTH),
                vesting_period: 36 * ONE_MONTH,
            });

            // Advisor
            vector::push_back(&mut pools, Allocation{
                max: advisor,
                minted: 0,
                tge_mint: 0,
                cliff_amount: advisor / 10, //10%
                cliff_start: now,
                cliff_period: 6 * ONE_MONTH,

                vesting_amount: advisor - (advisor / 10), // 100% - 10 %
                vesting_start: now + (6 * ONE_MONTH),
                vesting_period: 36 * ONE_MONTH,
            });

            // Launchpad
            vector::push_back(&mut pools, Allocation{
                max: launchpad,
                minted: 0,
                tge_mint: launchpad,
                cliff_amount: 0,
                cliff_start: 0,
                cliff_period: 0,

                vesting_amount: 0,
                vesting_start: 0,
                vesting_period: 0,
            });

            move_to(signer, AllocationStore{
                pools
            });
        }


        public entry fun claim(
            signer: &signer,
            poolId: u64,
            amount: u64,
            to: address
        ) acquires AllocationStore, Caps, Events {
            assert_admin(signer);
            assert!(exists<Events>(@HoustonCoin), ERROR_NO_EVENTS_RESOURCES);
            let store = borrow_global_mut<AllocationStore>(signer::address_of(signer));

            // compute claimmable amt and check against the amount want to mint
            let claimmable = pending_claim(store, poolId);
            assert!(amount <= claimmable, ERROR_PENDING_AMT_NOT_ENOUGH);
            if(amount == 0){
                amount = claimmable;
            };

            let pools = &mut store.pools;
            let allocation = vector::borrow_mut(pools, poolId);

            // update minted
            allocation.minted = allocation.minted + amount;

            // mint and deposit
            let caps = borrow_global<Caps<HOU>>(@HoustonCoin);
            let minted = coin::mint<HOU>(amount, &caps.mint);

            coin::deposit(to, minted);
            
            let events = &mut borrow_global_mut<Events>(@HoustonCoin).vesting_events;
            event::emit_event<VestingEvent>(
                events,
                VestingEvent{
                    poolId,
                    amount,
                    to
                }
            );

        }


        public fun pending_claim(store: &AllocationStore, poolId: u64): u64
        {
            let pools = & store.pools;
            let allocation = vector::borrow(pools, poolId);

            let now = timestamp::now_seconds();

            let entitled = allocation.tge_mint;

            // Cliff vesting
            if(allocation.cliff_amount > 0){
                let cliff_end = allocation.cliff_start + allocation.cliff_period;
                if(now >= cliff_end){
                    entitled = entitled + allocation.cliff_amount;
                }
            };

            // Normal vesting
            if(allocation.vesting_amount > 0 && now > allocation.vesting_start) {
                let rate: u128 = ((allocation.vesting_amount) as u128) * PRECISION / ((allocation.vesting_period) as u128);
                let vested = ((((now - allocation.vesting_start) as u128) * rate / PRECISION) as u64);
                entitled = entitled + vested;
            };

            let claimmable = if(entitled > allocation.minted) entitled - allocation.minted else 0;

            // take all left if reaching max
            if(allocation.minted + claimmable > allocation.max){
                claimmable = allocation.max - allocation.minted;
            };

            claimmable
        }



        public fun pending_supply(): u64 acquires SupplyInfo{
            let supply_info = borrow_global<SupplyInfo>(@HoustonCoin);
            pending_supply_info(supply_info)
            // let linear_vested = supply_info.supply_per_sec * (timestamp::now_seconds() - supply_info.last_supply_ts);
            // let pending = supply_info.acc_supply + linear_vested;
            // let total_minted: u128 = option::get_with_default(&coin::supply<HOU>(), 0);

            // if( (total_minted + (pending as u128) ) > (supply_info.max as u128) ) {
            //     // set pending to the remaining amount
            //     pending = (( (supply_info.max as u128) - total_minted) as u64);
            // };

            // pending
        }

        fun pending_supply_info(supply_info: &SupplyInfo): u64 {
            let linear_vested = supply_info.supply_per_sec * (timestamp::now_seconds() - supply_info.last_supply_ts);
            let pending = supply_info.acc_supply + linear_vested;
            let total_minted: u128 = option::get_with_default(&coin::supply<HOU>(), 0);

            if( (total_minted + (pending as u128) ) > (supply_info.max as u128) ) {
                // set pending to the remaining amount
                pending = (( (supply_info.max as u128) - total_minted) as u64);
            };

            pending
        }

        
        public fun mint(
            _authorized: &MiningCapability,
            amount: u64
        ) : coin::Coin<HOU> acquires SupplyInfo, Caps
        {
            assert!(exists<SupplyInfo>(@HoustonCoin), ERROR_SUPPLY_INFO);

            // validate total supply
            let supply_info = borrow_global<SupplyInfo>(@HoustonCoin);
            let total_minted: u128 = option::get_with_default(&coin::supply<HOU>(), 0);
            assert!(total_minted + (amount as u128) <= (supply_info.max as u128) , ERROR_MAX_OUT);

            // update accumulated supply
            let pending = pending_supply();
            let supply_info = borrow_global_mut<SupplyInfo>(@HoustonCoin);
            supply_info.acc_supply = pending;
            supply_info.last_supply_ts = timestamp::now_seconds();


            if(amount > 0)
            {
                // validate pending amount
                assert!(amount <= supply_info.acc_supply, ERROR_PENDING_AMT_NOT_ENOUGH);
                // remove from accumulated supply
                supply_info.acc_supply = supply_info.acc_supply - amount;

                let caps = borrow_global<Caps<HOU>>(@HoustonCoin);
                coin::mint<HOU>(amount, &caps.mint)
            }else{
                coin::zero<HOU>()
            }
        }


        /// return with MiningCapability witness to allow recipient module to mint
        public fun authorize_mining(account: &signer): MiningCapability {
            assert!(exists<SupplyInfo>(signer::address_of(account)), ERROR_NOT_OWNER);
            assert!(exists<Caps<HOU>>(signer::address_of(account)), ERROR_NOT_OWNER);
            MiningCapability{}
        }

        /// return with BurningCapability witness to allow recipient module to burn
        public fun authorize_burning(account: &signer): BurningCapability {
            assert!(exists<SupplyInfo>(signer::address_of(account)), ERROR_NOT_OWNER);
            assert!(exists<Caps<HOU>>(signer::address_of(account)), ERROR_NOT_OWNER);
            BurningCapability{}
        }


        /// with BurningCapability, allow other contract to burn HOU 
        public fun burn(_authorized: &BurningCapability, coins: coin::Coin<HOU>) acquires Caps{
            let caps = borrow_global<Caps<HOU>>(@HoustonCoin);
            coin::burn<HOU>(coins, &caps.burn);
        }

        // allow admin to burn HOU manually
        public entry fun manual_burn(account: &signer, amount: u64) acquires Caps, Events {
            assert!(exists<Caps<HOU>>(signer::address_of(account)), ERROR_NOT_OWNER);
            assert!(exists<Events>(@HoustonCoin), ERROR_NO_EVENTS_RESOURCES);

            let caps = borrow_global<Caps<HOU>>(signer::address_of(account));
            let burn_coin = coin::withdraw<HOU>(account, amount);
            coin::burn<HOU>(burn_coin, &caps.burn);
            
            let events = &mut borrow_global_mut<Events>(@HoustonCoin).manual_burn_events;
            event::emit_event<ManualBurnEvent>(
                events,
                ManualBurnEvent{amount}
            );

        }





        fun assert_admin(signer: &signer) {
            assert!(exists<Caps<HOU>>(signer::address_of((signer))), ERROR_NOT_OWNER);
        }


        #[test_only]
        public fun destroy_mining_cap(cap: MiningCapability){
            let MiningCapability { } = cap;
        }

        #[test_only]
        public fun destroy_burning_cap(cap: BurningCapability){
            let BurningCapability { } = cap;
        }


        /***
        *    .___________. _______     _______.___________.
        *    |           ||   ____|   /       |           |
        *    `---|  |----`|  |__     |   (----`---|  |----`
        *        |  |     |   __|     \   \       |  |     
        *        |  |     |  |____.----)   |      |  |     
        *        |__|     |_______|_______/       |__|     
        *                                                  
        */
 
        #[test_only]
        use aptos_framework::genesis;

        #[test_only]
        use aptos_std::debug;


        #[test(acc=@HoustonCoin)]
        fun test_create(acc: &signer)
        {
            genesis::setup();
            account::create_account_for_test(signer::address_of(acc));
            init_module(acc);
        }


        #[test(acc=@HoustonCoin)]
        fun test_minting(acc: &signer) acquires SupplyInfo, Caps
        {
            let addr = signer::address_of(acc);
            genesis::setup();
            account::create_account_for_test(addr);
            coin::register<HOU>(acc);

            init_module(acc);
            initialize_mining(acc);

            let cap = authorize_mining(acc);

            timestamp::fast_forward_seconds(60);
            let supply_info = borrow_global<SupplyInfo>(addr);
            let supply_60 = supply_info.supply_per_sec * 60;
            let pending = pending_supply();
            assert!(pending == supply_60, 0);
            let coins_minted = mint(&cap, pending);

            assert!(coin::value(&coins_minted) == pending, 0);
            coin::deposit(addr, coins_minted);

            destroy_mining_cap(cap);

            // check pending_supply must be 0
            assert!(pending_supply() == 0, 1);
        }


        #[test(acc=@HoustonCoin)]
        fun test_minting_half(acc: &signer) acquires SupplyInfo, Caps
        {
            let addr = signer::address_of(acc);
            
            genesis::setup();
            account::create_account_for_test(addr);
            coin::register<HOU>(acc);

            init_module(acc);
            initialize_mining(acc);

            let cap = authorize_mining(acc);

            timestamp::fast_forward_seconds(60*60);
            let pending = pending_supply();
            let coins_minted = mint(&cap, pending / 2);
            assert!(coin::value(&coins_minted) == pending / 2, 0);
            // debug::print<coin::Coin<HOU>>(&coins_minted);

            coin::deposit(addr, coins_minted);

            destroy_mining_cap(cap);

            // check pending_supply must have something
            let acc_supply = borrow_global<SupplyInfo>(@HoustonCoin).acc_supply;
            assert!(pending_supply() == pending / 2, 1);
            assert!(pending_supply() == acc_supply, 1);
        }


        #[test(acc=@HoustonCoin)]
        fun test_minting_max(acc: &signer) acquires SupplyInfo, Caps
        {
            genesis::setup();
            account::create_account_for_test(signer::address_of(acc));
            coin::register<HOU>(acc);

            init_module(acc);
            initialize_mining(acc);

            let cap = authorize_mining(acc);

            // fast forward 3 years + 1 mins
            timestamp::fast_forward_seconds(60*60*24*365*3 + 60);
            let pending = pending_supply();
            let info = borrow_global<SupplyInfo>(signer::address_of(acc));
            assert!(pending == info.max, 0);
            let coins_minted = mint(&cap, pending_supply());
            assert!(coin::value(&coins_minted) == pending, 0);

            debug::print<coin::Coin<HOU>>(&coins_minted);

            coin::deposit(signer::address_of(acc), coins_minted);

            destroy_mining_cap(cap);

            // check pending_supply must be 0
            assert!(pending_supply() == 0, 1);
        }



        #[test(acc=@HoustonCoin)]
        #[expected_failure(abort_code = 2)]
        fun test_minting_more_fail(acc: &signer) acquires SupplyInfo, Caps
        {
            let addr = signer::address_of(acc);
            genesis::setup();
            account::create_account_for_test(addr);
            coin::register<HOU>(acc);

            init_module(acc);
            initialize_mining(acc);

            let cap = authorize_mining(acc);

            // fast forward 3 years + 1 mins
            timestamp::fast_forward_seconds(60*60*24*365*3 + 60);
            let coins_minted = mint(&cap, pending_supply());
            coin::deposit(addr, coins_minted);

            // check pending_supply must be 0
            assert!(pending_supply() == 0, 1);

            // mint 1 more
            let coins_minted2 = mint(&cap, 1);
            // assert!(coin::value(&coins_minted2) == 0, 1);
            coin::destroy_zero(coins_minted2);

            destroy_mining_cap(cap);
        }

        #[test(acc=@HoustonCoin)]
        fun test_initialize_allocation(acc: &signer) acquires AllocationStore
        {
            let addr = signer::address_of(acc);
            genesis::setup();
            account::create_account_for_test(addr);
            coin::register<HOU>(acc);

            init_module(acc);
            initialize_mining(acc);
            initialize_allocation(acc);

            // let cap = authorize_mining(acc);


            timestamp::fast_forward_seconds(60);

            let pools = &borrow_global<AllocationStore>(addr).pools;
            assert!(vector::length(pools) == 4, 0);
            let i = 0;
            while(i < vector::length(pools)) {
                let pool = vector::borrow(pools, i);

                assert!(pool.max == pool.tge_mint + pool.cliff_amount + pool.vesting_amount, 0);
                assert!(pool.vesting_start > pool.cliff_start || (pool.vesting_start == 0 && pool.cliff_start == 0), 0);
                i = i + 1;
            };
        }

        #[test(acc=@HoustonCoin)]
        #[expected_failure(abort_code = 6)]
        fun test_initialize_allocation_twice_fail(acc: &signer)
        {
            let addr = signer::address_of(acc);
            genesis::setup();
            account::create_account_for_test(addr);
            coin::register<HOU>(acc);

            init_module(acc);
            initialize_allocation(acc);
            initialize_allocation(acc); // fail here

            
        }

        #[test(acc=@HoustonCoin,bob=@0x111)]
        #[expected_failure(abort_code = 1)]
        fun test_initialize_allocation_fail_not_owner(acc: &signer, bob: &signer)
        {
            let addr = signer::address_of(acc);
            genesis::setup();
            account::create_account_for_test(addr);
            coin::register<HOU>(acc);

            init_module(acc);
            initialize_allocation(bob);
            
        }

        #[test(acc=@HoustonCoin, alice=@0xA11CE)]
        fun test_claim_launch_pad(acc: &signer, alice: &signer) acquires AllocationStore, Caps, Events
        {
            let addr = signer::address_of(acc);
            let alice_addr = signer::address_of(alice);
            genesis::setup();
            account::create_account_for_test(addr);
            account::create_account_for_test(alice_addr);
            coin::register<HOU>(acc);
            coin::register<HOU>(alice);

            init_module(acc);
            initialize_mining(acc);
            initialize_allocation(acc);

            let launch_pad_pool = 3; 
            let alice_bal = coin::balance<HOU>(alice_addr);
            claim(acc, launch_pad_pool, 1000, alice_addr);
            let alice_bal_aft = coin::balance<HOU>(alice_addr);
            assert!(alice_bal_aft - alice_bal == 1000, 0);
            let pool = vector::borrow<Allocation>(&borrow_global<AllocationStore>(addr).pools, launch_pad_pool);
            assert!(pool.minted == 1000, 0);
            let claim_all = pool.max - pool.minted; 

            claim(acc, launch_pad_pool, claim_all, alice_addr);
            let alice_bal_aft_2 = coin::balance<HOU>(alice_addr);
            assert!(alice_bal_aft_2 - alice_bal_aft == claim_all, 0);

            let events = & borrow_global<Events>(@HoustonCoin).vesting_events;
            let counter = event::counter<VestingEvent>(events);
            assert!(counter == 2, 0);
        }

        #[test(acc=@HoustonCoin, alice=@0xA11CE)]
        #[expected_failure(abort_code = 1)]
        fun test_claim_fail_not_owner(acc: &signer, alice: &signer) acquires AllocationStore, Caps, Events
        {
            let addr = signer::address_of(acc);
            let alice_addr = signer::address_of(alice);
            genesis::setup();
            account::create_account_for_test(addr);
            account::create_account_for_test(alice_addr);
            coin::register<HOU>(acc);
            coin::register<HOU>(alice);

            init_module(acc);
            initialize_mining(acc);
            initialize_allocation(acc);

            let launch_pad_pool = 3; 
            claim(alice, launch_pad_pool, 1000, alice_addr);
            
        }

        #[test(acc=@HoustonCoin, alice=@0xA11CE)]
        #[expected_failure(abort_code = 5)]
        fun test_claim_fail_amount_too_much(acc: &signer, alice: &signer) acquires AllocationStore, Caps, Events
        {
            let addr = signer::address_of(acc);
            let alice_addr = signer::address_of(alice);
            genesis::setup();
            account::create_account_for_test(addr);
            account::create_account_for_test(alice_addr);
            coin::register<HOU>(acc);
            coin::register<HOU>(alice);

            init_module(acc);
            initialize_mining(acc);
            initialize_allocation(acc);

            let launch_pad_pool = 3; 
            claim(acc, launch_pad_pool, (1 << 63), alice_addr); // amount too large
            
        }

        #[test(acc=@HoustonCoin, alice=@0xA11CE)]
        fun test_claim_ecosystem(acc: &signer, alice: &signer) acquires AllocationStore, Caps, Events
        {
            let addr = signer::address_of(acc);
            let alice_addr = signer::address_of(alice);
            genesis::setup();
            account::create_account_for_test(addr);
            account::create_account_for_test(alice_addr);
            coin::register<HOU>(acc);
            coin::register<HOU>(alice);

            init_module(acc);
            initialize_mining(acc);
            initialize_allocation(acc);

            let ecosystem_pool = 0; 
            let alice_bal = coin::balance<HOU>(alice_addr);
            let pool = vector::borrow<Allocation>(&borrow_global<AllocationStore>(addr).pools, ecosystem_pool);
            let tge_amt = pool.max * 5 / 100;
            let vesting_max = pool.max - tge_amt;
            // tge
            claim(acc, ecosystem_pool, tge_amt, alice_addr);
            let pool = vector::borrow<Allocation>(&borrow_global<AllocationStore>(addr).pools, ecosystem_pool);
            assert!(pool.minted == tge_amt, 0);
            let alice_bal_aft = coin::balance<HOU>(alice_addr);
            assert!(alice_bal_aft - alice_bal == tge_amt, 0);
            
            let pending = pending_claim(borrow_global<AllocationStore>(addr), ecosystem_pool);
            assert!(pending == 0, 0);
            
            timestamp::fast_forward_seconds(1);
            let pending = pending_claim(borrow_global<AllocationStore>(addr), ecosystem_pool);
            assert!(pending > 0, 0);

            timestamp::fast_forward_seconds(24 * ONE_MONTH + 1); // need to add 1 due to precision issue
            let pending = pending_claim(borrow_global<AllocationStore>(addr), ecosystem_pool);
            assert!(pending == vesting_max, 0);
            claim(acc, ecosystem_pool, vesting_max, alice_addr);
            timestamp::fast_forward_seconds(1); 
            let pending = pending_claim(borrow_global<AllocationStore>(addr), ecosystem_pool);
            assert!(pending == 0, 0); // pending still equals 1

        }

        #[test(acc=@HoustonCoin, alice=@0xA11CE)]
        fun test_claim_team(acc: &signer, alice: &signer) acquires AllocationStore, Caps, Events
        {
            let addr = signer::address_of(acc);
            let alice_addr = signer::address_of(alice);
            genesis::setup();
            account::create_account_for_test(addr);
            account::create_account_for_test(alice_addr);
            coin::register<HOU>(acc);
            coin::register<HOU>(alice);

            init_module(acc);
            initialize_mining(acc);
            initialize_allocation(acc);

            let team_pool = 1; 
            let _alice_bal = coin::balance<HOU>(alice_addr);
            let pool = vector::borrow<Allocation>(&borrow_global<AllocationStore>(addr).pools, team_pool);
            let cliff_max = pool.max / 10;
            let vesting_max = pool.max - cliff_max;
            let vesting_rate = (vesting_max as u128) * PRECISION / (pool.vesting_period as u128);
            // tge = 0
            timestamp::fast_forward_seconds(3);
            let pending = pending_claim(borrow_global<AllocationStore>(addr), team_pool);
            assert!(pending == 0, 0);
            // cliff
            timestamp::fast_forward_seconds(6 * ONE_MONTH - timestamp::now_seconds());
            let pending = pending_claim(borrow_global<AllocationStore>(addr), team_pool);
            assert!(pending == cliff_max, 0);
            claim(acc, team_pool, cliff_max, alice_addr);
            let pool = vector::borrow<Allocation>(&borrow_global<AllocationStore>(addr).pools, team_pool);
            assert!(pool.minted == cliff_max, 0);
            
            //vesting
            timestamp::fast_forward_seconds(ONE_MONTH);
            let pending = pending_claim(borrow_global<AllocationStore>(addr), team_pool);
            let pending_cal = (((ONE_MONTH as u128) * vesting_rate / PRECISION) as u64);
            assert!(pending == pending_cal && pending > 0, 0);


        }

        #[test(acc=@HoustonCoin)]
        fun test_manual_burn(acc: &signer) acquires SupplyInfo, Caps, Events
        {
            genesis::setup();
            account::create_account_for_test(signer::address_of(acc));
            coin::register<HOU>(acc);

            init_module(acc);
            initialize_mining(acc);

            let cap = authorize_mining(acc);
            
            // fast forward 3 years + 1 mins
            timestamp::fast_forward_seconds(60*60*24*365*3 + 60);
            let pending = pending_supply();
            let info = borrow_global<SupplyInfo>(signer::address_of(acc));
            assert!(pending == info.max, 0);
            let coins_minted = mint(&cap, pending_supply());
            assert!(coin::value(&coins_minted) == pending, 0);

            debug::print<coin::Coin<HOU>>(&coins_minted);

            coin::deposit(signer::address_of(acc), coins_minted);
            manual_burn(acc, pending);
            assert!(coin::balance<HOU>(signer::address_of(acc)) == 0, 0);
            destroy_mining_cap(cap);

            let events = &borrow_global<Events>(@HoustonCoin).manual_burn_events;
            let counter = event::counter<ManualBurnEvent>(events);
            assert!(counter == 1, 0);


        }

        #[test(acc=@HoustonCoin, bob=@0xB0B)]
        #[expected_failure(abort_code = 1)]
        fun test_manual_burn_fail_not_owner(acc: &signer, bob: &signer) acquires SupplyInfo, Caps, Events
        {
            genesis::setup();
            account::create_account_for_test(signer::address_of(acc));
            coin::register<HOU>(acc);

            init_module(acc);
            initialize_mining(acc);

            let cap = authorize_mining(acc);
            
            // fast forward 3 years + 1 mins
            timestamp::fast_forward_seconds(60*60*24*365*3 + 60);
            let coins_minted = mint(&cap, pending_supply());
            
            debug::print<coin::Coin<HOU>>(&coins_minted);

            coin::deposit(signer::address_of(acc), coins_minted);
            manual_burn(bob, 1);
            destroy_mining_cap(cap);

        }




    }

}