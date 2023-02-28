address HoustonLaunchPad {

module hou_ido{
    // use aptos_framework::type_info::{Self, TypeInfo};
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::aptos_coin::{AptosCoin};
    use aptos_framework::account;
    use std::signer;
    use aptos_framework::event::{Self, EventHandle};
    use std::timestamp;
    
    struct Pool<phantom CoinType> has key {
        distribute_start_time: u64,
        start_time: u64,
        end_time: u64,
        payment_coins: Coin<AptosCoin>,
        total_payment_amount: u64, 
        offer_coins: Coin<CoinType>,
        max_raised: u64,
        sale_price: u128, // tokens out / max_raised * PRICE_PRECISION
        treasury: address,
        events: PoolEvents<CoinType>
    }

    struct UserInfo<phantom CoinType> has key {
        amount: u64,
        claimmed: u64
    }

    struct PoolEvents<phantom CoinType> has store {
        pool_created_events: EventHandle<PoolCreatedEvent<CoinType>>,
        deposit_events: EventHandle<DepositEvent<CoinType>>,
        claim_events: EventHandle<ClaimEvent<CoinType>>,
        withdraw_payment_events: EventHandle<WithdrawPaymentEvent<CoinType>>
    }

    struct PoolCreatedEvent<phantom CoinType> has store, drop {
        total_distribute_amt: u64,
        max_raised: u64,
        sale_price: u128
    }

    struct DepositEvent<phantom CoinType> has store, drop {
        user: address, 
        amount: u64,
    }

    struct ClaimEvent<phantom CoinType> has store, drop {
        user: address,
        claimmed: u64
    }

    struct WithdrawPaymentEvent<phantom CoinType> has store, drop {
        to: address,
        amount: u64
    }


    const ERROR_NOT_ADMIN: u64 = 1;
    /// Pool does not exists
    const ERROR_NO_POOLS: u64 = 2;
    const ERROR_DEPOSIT_TIME: u64 = 3;
    const ERROR_DISTRIBUTE_TIME: u64 = 4;
    const ERROR_POOL_DUPLICATES: u64 = 5;
    const ERROR_TIME_ORDER: u64 = 6;
    /// The Pool has reached maximum commitment
    const ERROR_CAP: u64 = 7;
    const ERROR_TREASURY: u64 = 8;
    /// Distribution of offered coin has not started
    const ERROR_CLAIM_TIME: u64 = 9;
    /// You have not participated in this offering
    const ERROR_NO_DEPOSIT: u64 = 10;
    const ERROR_WITHDRAW_PAYMENT_TIME: u64 = 11;
    const ERROR_WITHDRAW_ZERO_AMT: u64 = 12;
    const ERROR_CLAIMMED: u64 = 13;

    const EQUAL: u8 = 0;
    const LESS_THAN: u8 = 1;
    const GREATER_THAN: u8 = 2;

    const PRICE_PRECISION: u128 = 1000000000000; // 1e12
    
    public fun assert_admin(account: &signer) {
        assert!(signer::address_of(account) == @HoustonLaunchPad, ERROR_NOT_ADMIN);
    }


    /// Claim offering coins after distribution started
    public entry fun claim<CoinType> (account: &signer) acquires UserInfo, Pool {
        // Check pool
        assert!(exists<Pool<CoinType>>(@HoustonLaunchPad), ERROR_NO_POOLS);
        // Check time
        let pool = borrow_global_mut<Pool<CoinType>>(@HoustonLaunchPad);
        let now = timestamp::now_seconds();
        assert!(pool.distribute_start_time <= now , ERROR_CLAIM_TIME);

        // check qualification
        let user = signer::address_of(account);
        assert!(exists<UserInfo<CoinType>>(user), ERROR_NO_DEPOSIT);
        
        // compute eligible amount of offered coins
        let user_info = borrow_global_mut<UserInfo<CoinType>>(user);
        let pool = borrow_global_mut<Pool<CoinType>>(@HoustonLaunchPad); 
        let entitledAmt = ((pool.sale_price * (user_info.amount as u128) / PRICE_PRECISION) as u64);
        let claimmableAmt = entitledAmt - user_info.claimmed;
        assert!(claimmableAmt > 0, ERROR_CLAIMMED);
        user_info.claimmed = user_info.claimmed + claimmableAmt;
        // make sure user able to receive coin
        if(!coin::is_account_registered<CoinType>(user)) {
            coin::register<CoinType>(account);
        };

        // distribute the coin
        let tokens_claimmable = coin::extract(&mut pool.offer_coins, claimmableAmt);
        coin::deposit<CoinType>(user, tokens_claimmable);
        
        // write event
        let events = &mut pool.events.claim_events;
        event::emit_event<ClaimEvent<CoinType>>(
            events,
            ClaimEvent<CoinType> {
                user, 
                claimmed: claimmableAmt
            }
        );
    }


    /// Create a launch pool
    public entry fun create_launch<CoinType>(
        admin: &signer,
        treasury: address,
        start_time: u64,
        end_time: u64,
        distribute_start: u64,
        total_offer_coins: u64,
        max_raised: u64
    ) acquires Pool{
        assert_admin(admin);
        assert!(!exists<Pool<CoinType>>(@HoustonLaunchPad), ERROR_POOL_DUPLICATES);

        // sanity check on deposit start and deposit end
        let now = timestamp::now_seconds();
        assert!(now <= start_time && start_time < end_time && end_time < distribute_start, ERROR_TIME_ORDER);

        // max_raised must be non zero
        assert!(max_raised > 0, ERROR_CAP);

        // Treasury must be an address that can receive payment coins
        assert!(coin::is_account_registered<AptosCoin>(treasury), ERROR_TREASURY);

        // Create Pool
        let sale_price = PRICE_PRECISION * (total_offer_coins as u128) / (max_raised as u128);
        move_to(admin, Pool<CoinType>{
            distribute_start_time: distribute_start,
            start_time: start_time,
            end_time: end_time,
            offer_coins: coin::withdraw(admin, total_offer_coins),
            payment_coins: coin::zero<AptosCoin>(),
            total_payment_amount: 0, 
            max_raised,
            sale_price,
            treasury,
            events: PoolEvents{
                pool_created_events: account::new_event_handle<PoolCreatedEvent<CoinType>>(admin),
                deposit_events: account::new_event_handle<DepositEvent<CoinType>>(admin),
                claim_events: account::new_event_handle<ClaimEvent<CoinType>>(admin),
                withdraw_payment_events: account::new_event_handle<WithdrawPaymentEvent<CoinType>>(admin),
            }
        });

        // events
        let pool = borrow_global_mut<Pool<CoinType>>(@HoustonLaunchPad);
        let events = &mut pool.events.pool_created_events;
        event::emit_event<PoolCreatedEvent<CoinType>>(
            events,
            PoolCreatedEvent<CoinType> {
                total_distribute_amt: total_offer_coins,
                max_raised,
                sale_price
            }
        );
    }

    /// for devnet test only?
    public entry fun update_launch<CoinType>(
        admin: &signer,
        end_time: u64,
        distribute_start: u64,
    ) acquires Pool{
        assert_admin(admin);

        assert!(exists<Pool<CoinType>>(@HoustonLaunchPad), ERROR_NO_POOLS);

        // validate end_time and distribute_start must be future time
        assert!(end_time > timestamp::now_seconds() && distribute_start > timestamp::now_seconds(), ERROR_TIME_ORDER);
        assert!(distribute_start >= end_time, ERROR_TIME_ORDER);
        assert!(end_time > borrow_global<Pool<CoinType>>(@HoustonLaunchPad).start_time, ERROR_TIME_ORDER);

        let pool = borrow_global_mut<Pool<CoinType>>(@HoustonLaunchPad);
        pool.end_time = end_time;
        pool.distribute_start_time = distribute_start;
    }


    /// deposit payment tokens to participate the sale
    public entry fun deposit<CoinType>(account: &signer, amount: u64) acquires UserInfo, Pool
    {
        // Check Pool
        assert!(exists<Pool<CoinType>>(@HoustonLaunchPad), ERROR_NO_POOLS);

        // Check Time and quota
        let pool = borrow_global_mut<Pool<CoinType>>(@HoustonLaunchPad);
        let now = timestamp::now_seconds();
        assert!(now >= pool.start_time && now <= pool.end_time, ERROR_DEPOSIT_TIME);
        assert!(pool.max_raised > pool.total_payment_amount, ERROR_CAP);

        if(pool.max_raised - pool.total_payment_amount < amount) {
            amount = pool.max_raised - pool.total_payment_amount;
        }; 
        pool.total_payment_amount = pool.total_payment_amount + amount; 
        let acc_addr = signer::address_of(account);
        let withdraw_amt = coin::withdraw<AptosCoin>(account, amount);
        coin::merge<AptosCoin>(&mut pool.payment_coins, withdraw_amt);
        
        if(!exists<UserInfo<CoinType>>(acc_addr)){
            move_to(account, UserInfo<CoinType>{
                amount,
                claimmed: 0
            });
        }else {
            let info = borrow_global_mut<UserInfo<CoinType>>(acc_addr);
            info.amount = info.amount + amount;
        };
        
        // generate events
        let events = &mut pool.events.deposit_events;
        event::emit_event<DepositEvent<CoinType>>(
            events,
            DepositEvent<CoinType> {
                user: acc_addr, 
                amount
            }
        );
    }

    /// admin withdraw payment coins, only shortly before distribution
    public entry fun withdraw_payment<CoinType>(treasury: &signer) acquires Pool
    {   
        // check pool
        assert!(exists<Pool<CoinType>>(@HoustonLaunchPad), ERROR_NO_POOLS);

        // check id
        let pool = borrow_global_mut<Pool<CoinType>>(@HoustonLaunchPad);
        assert!(signer::address_of(treasury) == pool.treasury, ERROR_TREASURY);

        // check time constraint
        let now = timestamp::now_seconds();
        assert!(pool.end_time < now, ERROR_WITHDRAW_PAYMENT_TIME);

        // check amount
        let amount = coin::value<AptosCoin>(&pool.payment_coins);
        assert!(amount > 0, ERROR_WITHDRAW_ZERO_AMT);

        // make sure user can receive payment coin
        if(!coin::is_account_registered<AptosCoin>(pool.treasury)) {
            coin::register<AptosCoin>(treasury);
        };

        // transfer the payment
        coin::deposit<AptosCoin>(pool.treasury, coin::extract_all<AptosCoin>(&mut pool.payment_coins));

        // write event
        event::emit_event<WithdrawPaymentEvent<CoinType>>(
            &mut pool.events.withdraw_payment_events,
            WithdrawPaymentEvent<CoinType> {
                to: pool.treasury,
                amount
            }
        );
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
    use HoustonDevTools::dev::{Self, USDT};

    // #[test_only]
    // use aptos_framework::aptos_coin::{Self};
        
        
    #[test(acc=@HoustonSwap, alice=@0xA11CE, aptos=@0x1)]
    fun test_launch(acc: &signer, alice: &signer, aptos: &signer) acquires Pool{
        // 0. setup
        timestamp::set_time_has_started_for_testing(aptos);
        let now = timestamp::now_seconds();
        dev::aptos_faucet(aptos, acc, 10000000000);
        dev::create_account_for_test(alice);
        coin::register<AptosCoin>(alice);
        coin::transfer<AptosCoin>(acc, signer::address_of(alice), 1000000000);
        dev::register_coins(acc);
        dev::initialize_coins(acc);
        coin::deposit<USDT>(signer::address_of(acc), dev::mint_for_test<USDT>(acc, 1000000));
        
        // 1. launch
        create_launch<USDT>(acc, signer::address_of(acc), now + 100, now + 200, now + 300, 1000000, 100000);
        assert!(exists<Pool<USDT>>(signer::address_of(acc)), 0);
        let pool = borrow_global<Pool<USDT>>(signer::address_of(acc));
        assert!(pool.start_time == now + 100, 0);
        assert!(pool.end_time == now + 200, 0);
        assert!(pool.distribute_start_time == now + 300, 0);
        assert!(coin::value<USDT>(&pool.offer_coins) == 1000000, 0);
        assert!(pool.max_raised == 100000, 0);
        assert!(coin::value<AptosCoin>(&pool.payment_coins) == 0, 0);
        assert!(pool.treasury == signer::address_of(acc), 0);
        
    }

    #[test(acc=@HoustonSwap, alice=@0xA11CE, aptos=@0x1)]
    #[expected_failure(abort_code = 6, location = Self)]
    fun test_launch_fail_time_0(acc: &signer, alice: &signer, aptos: &signer) acquires Pool{
        // 0. setup
        timestamp::set_time_has_started_for_testing(aptos);
        let now = timestamp::now_seconds();
        dev::aptos_faucet(aptos, acc, 10000000000);
        dev::create_account_for_test(alice);
        coin::register<AptosCoin>(alice);
        coin::transfer<AptosCoin>(acc, signer::address_of(alice), 1000000000);
        dev::register_coins(acc);
        dev::initialize_coins(acc);
        coin::deposit<USDT>(signer::address_of(acc), dev::mint_for_test<USDT>(acc, 1000000));
        
        // deposit end time < deposit start time
        create_launch<USDT>(acc, signer::address_of(acc), now + 100, now + 50, now + 300, 1000000, 10000);
    }

    #[test(acc=@HoustonSwap, alice=@0xA11CE, aptos=@0x1)]
    #[expected_failure(abort_code = 6, location = Self)]
    fun test_launch_fail_time_1(acc: &signer, alice: &signer, aptos: &signer) acquires Pool{
        // 0. setup
        timestamp::set_time_has_started_for_testing(aptos);
        dev::aptos_faucet(aptos, acc, 10000000000);
        dev::create_account_for_test(alice);
        coin::register<AptosCoin>(alice);
        coin::transfer<AptosCoin>(acc, signer::address_of(alice), 1000000000);
        dev::register_coins(acc);
        dev::initialize_coins(acc);
        coin::deposit<USDT>(signer::address_of(acc), dev::mint_for_test<USDT>(acc, 1000000));
        
        // deposit end time ==  distribute time
        create_launch<USDT>(acc, signer::address_of(acc), 100, 200, 200, 1000000, 10000);
    }

    #[test(acc=@HoustonSwap, alice=@0xA11CE, aptos=@0x1)]
    #[expected_failure(abort_code = 6, location = Self)]
    fun test_launch_fail_time_2(acc: &signer, alice: &signer, aptos: &signer) acquires Pool{
        // 0. setup
        timestamp::set_time_has_started_for_testing(aptos);
        dev::aptos_faucet(aptos, acc, 10000000000);
        dev::create_account_for_test(alice);
        coin::register<AptosCoin>(alice);
        coin::transfer<AptosCoin>(acc, signer::address_of(alice), 1000000000);
        dev::register_coins(acc);
        dev::initialize_coins(acc);
        coin::deposit<USDT>(signer::address_of(acc), dev::mint_for_test<USDT>(acc, 1000000));
        timestamp::fast_forward_seconds(100);
        // deposit end time ==  distribute time
        create_launch<USDT>(acc, signer::address_of(acc), 80, 200, 300, 1000000, 10000);
    }

    #[test(acc=@HoustonSwap, alice=@0xA11CE, bob=@0xB0B, aptos=@0x1)]
    fun test_stake(acc: &signer, alice: &signer, bob: &signer, aptos: &signer) acquires Pool, UserInfo {
        let alice_addr = signer::address_of(alice);
        // 0. setup and launch
        test_launch(acc, alice, aptos);
        dev::create_account_for_test(bob);
        coin::register<AptosCoin>(bob);
        coin::transfer<AptosCoin>(acc, signer::address_of(bob), 1000000000);
        
        
        // 1. alice deposit
        timestamp::fast_forward_seconds(100);
        let init_apt = coin::balance<AptosCoin>(alice_addr);
        deposit<USDT>(alice, 10000);
        let aft_apt = coin::balance<AptosCoin>(alice_addr);
        
        let userInfo = borrow_global<UserInfo<USDT>>(alice_addr);
        assert!(userInfo.amount == 10000, 0);
        assert!(init_apt - aft_apt == 10000, 0);
        let pool = borrow_global<Pool<USDT>>(signer::address_of(acc));
        let total_amount_in = coin::value<AptosCoin>(&pool.payment_coins);
        let cap_remaining = pool.max_raised - total_amount_in;
        assert!(total_amount_in == userInfo.amount, 0);
        
        // 2. bob deposit again. deposit above the max_raised
        timestamp::fast_forward_seconds(10);
        let bob_addr = signer::address_of(bob);
        let init_apt_b = coin::balance<AptosCoin>(bob_addr);
        deposit<USDT>(bob, cap_remaining + 100);
        let aft_apt_b = coin::balance<AptosCoin>(bob_addr);
        
        let userInfo = borrow_global<UserInfo<USDT>>(bob_addr);
        assert!(userInfo.amount == cap_remaining, 0);
        assert!(init_apt_b - aft_apt_b == cap_remaining, 0);
        let pool_2 = borrow_global<Pool<USDT>>(signer::address_of(acc));
        assert!(coin::value<AptosCoin>(&pool_2.payment_coins) == pool_2.max_raised, 0);
        
    }

    #[test(acc=@HoustonSwap, alice=@0xA11CE, bob=@0xB0B, aptos=@0x1)]
    fun test_with_ugly_numbers(acc: &signer, alice: &signer, bob: &signer, aptos: &signer) acquires Pool, UserInfo {
        let alice_addr = signer::address_of(alice);
        // 0. setup and launch
        timestamp::set_time_has_started_for_testing(aptos);
        let aptos_mint_amt = 100000000000;
        dev::aptos_faucet(aptos, acc, aptos_mint_amt);
        dev::create_account_for_test(alice);
        coin::register<AptosCoin>(alice);
        coin::transfer<AptosCoin>(acc, signer::address_of(alice), aptos_mint_amt/20);
        dev::register_coins(acc);
        dev::initialize_coins(acc);
        let token_out_amt:u64 = 1203354354345679454;
        coin::deposit<USDT>(signer::address_of(acc), dev::mint_for_test<USDT>(acc, token_out_amt));
        
        // 1. launch
        let max_raised = 2456000000;
        let sale_price:u128 = (token_out_amt as u128) * (PRICE_PRECISION) / (max_raised as u128);
        
        create_launch<USDT>(acc, signer::address_of(acc), 100, 200, 300, token_out_amt, max_raised);
        let pool = borrow_global<Pool<USDT>>(signer::address_of(acc));
        assert!(pool.sale_price == sale_price, 0);
        dev::create_account_for_test(bob);
        coin::register<AptosCoin>(bob);
        coin::transfer<AptosCoin>(acc, signer::address_of(bob), aptos_mint_amt/20);
        
        
        // 1. alice deposit
        timestamp::fast_forward_seconds(100);
        let init_apt = coin::balance<AptosCoin>(alice_addr);
        let _trea_init_apt = coin::balance<AptosCoin>(signer::address_of(acc));
        let alice_stake_amt = 34454;
        deposit<USDT>(alice, alice_stake_amt);
        let aft_apt = coin::balance<AptosCoin>(alice_addr);
        let _trea_aft_apt = coin::balance<AptosCoin>(signer::address_of(acc));
        
        let userInfo = borrow_global<UserInfo<USDT>>(alice_addr);
        assert!(userInfo.amount == alice_stake_amt, 0);
        assert!(init_apt - aft_apt == alice_stake_amt, 0);
        
        // 2. bob deposit again. deposit above the max_raised
        timestamp::fast_forward_seconds(10);
        let bob_addr = signer::address_of(bob);
        let init_apt_b = coin::balance<AptosCoin>(bob_addr);
        let _trea_init_apt = coin::balance<AptosCoin>(signer::address_of(acc));
        let bob_stake_amt = 54395;
        deposit<USDT>(bob, bob_stake_amt);
        
        let aft_apt_b = coin::balance<AptosCoin>(bob_addr);
        let _trea_aft_apt = coin::balance<AptosCoin>(signer::address_of(acc));
        
        let userInfo = borrow_global<UserInfo<USDT>>(bob_addr);
        assert!(userInfo.amount == bob_stake_amt, 0);
        assert!(init_apt_b - aft_apt_b == bob_stake_amt, 0);

        // 3. acc deposit again. deposit above the max_raised
        timestamp::fast_forward_seconds(10);
        let acc_addr = signer::address_of(acc);
        let pool = borrow_global<Pool<USDT>>(signer::address_of(acc));
        let total_amount_in = coin::value<AptosCoin>(&pool.payment_coins);
        assert!(pool.total_payment_amount == total_amount_in, 0);
        let acc_stake_amt = pool.max_raised - total_amount_in;
        let init_apt_a = coin::balance<AptosCoin>(acc_addr);
        deposit<USDT>(acc, acc_stake_amt + 10);
        let aft_apt_a = coin::balance<AptosCoin>(acc_addr);
        
        let userInfo = borrow_global<UserInfo<USDT>>(acc_addr);
        assert!(userInfo.amount == acc_stake_amt, 0);
        assert!(init_apt_a - aft_apt_a == acc_stake_amt, 0);
        // assert!(init_apt_a == aft_apt_a, 0);
        let pool = borrow_global<Pool<USDT>>(signer::address_of(acc));
        let total_amount_in = coin::value<AptosCoin>(&pool.payment_coins);
        assert!(pool.max_raised == total_amount_in, 0);

        // 4. claim
        timestamp::fast_forward_seconds(500);
        let sale_price = pool.sale_price;
        let claimmable = ((sale_price * (alice_stake_amt as u128) / PRICE_PRECISION) as u64);
        claim<USDT>(alice);
        let aft_usdt = coin::balance<USDT>(alice_addr);
        assert!(aft_usdt == claimmable, 0);
        let claimmable = ((sale_price * (bob_stake_amt as u128) / PRICE_PRECISION) as u64);
        claim<USDT>(bob);
        let aft_usdt = coin::balance<USDT>(bob_addr);
        assert!(aft_usdt == claimmable , 0);
        let init_usdt = coin::balance<USDT>(acc_addr);
        let claimmable = ((sale_price * (acc_stake_amt as u128) / PRICE_PRECISION) as u64);
        claim<USDT>(acc);
        let aft_usdt = coin::balance<USDT>(acc_addr);
        assert!(aft_usdt - init_usdt == claimmable, 0);

        let pool = borrow_global<Pool<USDT>>(signer::address_of(acc));
        let left = coin::value<USDT>(&pool.offer_coins);
        assert!((left as u128) * PRICE_PRECISION / sale_price == 0, 0); // some left over but not much
        assert!(left > 0, 0); // some left over but not much
        assert!(pool.total_payment_amount == total_amount_in, 0);
        
    }



    #[test(acc=@HoustonSwap, alice=@0xA11CE, bob=@0xB0B, aptos=@0x1)]
    #[expected_failure(abort_code = 7, location = Self)]
    fun test_stake_fail_cap_over(acc: &signer, alice: &signer, bob: &signer, aptos: &signer) acquires Pool, UserInfo {
        // 0. setup and launch
        test_launch(acc, alice, aptos);
        dev::create_account_for_test(bob);
        coin::register<AptosCoin>(bob);
        coin::transfer<AptosCoin>(acc, signer::address_of(bob), 1000000000);
        
        
        // 1. alice deposit
        timestamp::fast_forward_seconds(100);
        let pool_0 = borrow_global<Pool<USDT>>(signer::address_of(acc));
        let max_raised = pool_0.max_raised;
        deposit<USDT>(alice, max_raised);
        
        let pool = borrow_global<Pool<USDT>>(signer::address_of(acc));
        assert!(pool.max_raised == coin::value<AptosCoin>(&pool.payment_coins), 0);
        
        // 2. bob deposit again. but should fail
        timestamp::fast_forward_seconds(10);
        deposit<USDT>(bob, 1);
        
    }

    #[test(acc=@HoustonSwap, alice=@0xA11CE, bob=@0xB0B, aptos=@0x1)]
    #[expected_failure(abort_code = 2, location = Self)]
    fun test_stake_fail_no_pool(acc: &signer, alice: &signer, bob: &signer, aptos: &signer) acquires Pool, UserInfo {
        // 0. setup and launch
        test_launch(acc, alice, aptos);
        dev::create_account_for_test(bob);
        coin::register<AptosCoin>(bob);
        coin::transfer<AptosCoin>(acc, signer::address_of(bob), 1000000000);
        
        // 1. alice deposit on wrong token pool
        timestamp::fast_forward_seconds(100);
        deposit<AptosCoin>(alice, 1);
    }

    #[test(acc=@HoustonSwap, alice=@0xA11CE, bob=@0xB0B, aptos=@0x1)]
    #[expected_failure(abort_code = 3, location = Self)]
    fun test_stake_fail_time(acc: &signer, alice: &signer, bob: &signer, aptos: &signer) acquires Pool, UserInfo {
        // 0. setup and launch
        test_launch(acc, alice, aptos);
        dev::create_account_for_test(bob);
        coin::register<AptosCoin>(bob);
        coin::transfer<AptosCoin>(acc, signer::address_of(bob), 1000000000);
    
        // 1. alice deposit on wrong token pool
        deposit<USDT>(alice, 1);
    }

    #[test(acc=@HoustonSwap, alice=@0xA11CE, bob=@0xB0B, aptos=@0x1)]
    #[expected_failure(abort_code = 3, location = Self)]
    fun test_stake_fail_time_1(acc: &signer, alice: &signer, bob: &signer, aptos: &signer) acquires Pool, UserInfo {
        // 0. setup and launch
        test_launch(acc, alice, aptos);
        dev::create_account_for_test(bob);
        coin::register<AptosCoin>(bob);
        coin::transfer<AptosCoin>(acc, signer::address_of(bob), 1000000000);
    
        // 1. alice deposit on wrong token pool
        timestamp::fast_forward_seconds(10000);
        deposit<USDT>(alice, 1);
    }

    #[test(acc=@HoustonSwap, alice=@0xA11CE, bob=@0xB0B, aptos=@0x1)]
    fun test_claim(acc: &signer, alice: &signer, bob: &signer, aptos: &signer) acquires Pool, UserInfo {
        test_stake(acc, alice, bob, aptos);
        let alice_addr = signer::address_of(alice);
        let user_info = borrow_global<UserInfo<USDT>>(alice_addr);
        let pool = borrow_global<Pool<USDT>>(signer::address_of(acc));
        let claimmable = (((user_info.amount as u128) * pool.sale_price / PRICE_PRECISION) as u64);
        timestamp::fast_forward_seconds(400);
        dev::register_coins(alice);
        let init_usdt = coin::balance<USDT>(alice_addr);
        let tokens_out_bef = coin::value<USDT>(&pool.offer_coins);
        claim<USDT>(alice);
        let aft_usdt = coin::balance<USDT>(alice_addr);
        assert!(aft_usdt - init_usdt == claimmable, 0);
        let user_info = borrow_global<UserInfo<USDT>>(alice_addr);
        assert!(user_info.claimmed == claimmable, 0);
        let pool = borrow_global<Pool<USDT>>(signer::address_of(acc));
        let tokens_out_aft = coin::value<USDT>(&pool.offer_coins);
        assert!(tokens_out_bef - tokens_out_aft == claimmable, 0);
    }
    
    #[test(acc=@HoustonSwap, alice=@0xA11CE, bob=@0xB0B, aptos=@0x1)]
    #[expected_failure(abort_code = 13, location = Self)]
    fun test_claim_fail(acc: &signer, alice: &signer, bob: &signer, aptos: &signer) acquires Pool, UserInfo {
        test_stake(acc, alice, bob, aptos);
        timestamp::fast_forward_seconds(400);
        dev::register_coins(alice);
        claim<USDT>(alice);
        claim<USDT>(alice); // unable to claim twice
        
    }

    #[test(acc=@HoustonSwap, alice=@0xA11CE, bob=@0xB0B, aptos=@0x1)]
    fun test_withdraw_payment(acc: &signer, alice: &signer, bob: &signer, aptos: &signer) acquires Pool, UserInfo {
        test_stake(acc, alice, bob, aptos);
        let acc_addr = signer::address_of(acc);
        let pool = borrow_global<Pool<USDT>>(signer::address_of(acc));
        timestamp::fast_forward_seconds(400);
        let init_apt = coin::balance<AptosCoin>(acc_addr);
        let left = coin::value<AptosCoin>(&pool.payment_coins);
        withdraw_payment<USDT>(acc);
        let aft_apt = coin::balance<AptosCoin>(acc_addr);
        assert!(aft_apt - init_apt == left, 0);
        let pool = borrow_global<Pool<USDT>>(signer::address_of(acc));
        assert!(coin::value<AptosCoin>(&pool.payment_coins) == 0, 0);
    }

    
    #[test(acc=@HoustonSwap, alice=@0xA11CE, aptos=@0x1)]
    #[expected_failure(abort_code = 11, location = Self)]
    fun test_withdraw_payment_fail_time(acc: &signer, alice: &signer, aptos: &signer) acquires Pool, UserInfo {
        // 0. setup
        timestamp::set_time_has_started_for_testing(aptos);
        // let now = timestamp::now_seconds();
        dev::aptos_faucet(aptos, acc, 10000000000);
        dev::create_account_for_test(alice);
        coin::register<AptosCoin>(alice);
        coin::transfer<AptosCoin>(acc, signer::address_of(alice), 1000000000);
        dev::register_coins(acc);
        dev::initialize_coins(acc);
        coin::deposit<USDT>(signer::address_of(acc), dev::mint_for_test<USDT>(acc, 1000000));
        
        // 1. launch
        create_launch<USDT>(acc, signer::address_of(acc), 100, 200, 300, 1000000, 100000);
        timestamp::fast_forward_seconds(100);
        
        deposit<USDT>(acc, 100000);
        withdraw_payment<USDT>(acc);
    }

    #[test(acc=@HoustonSwap, alice=@0xA11CE, bob=@0xB0B, aptos=@0x1)]
    #[expected_failure(abort_code = 8, location = Self)]
    fun test_withdraw_payment_fail_treasury(acc: &signer, alice: &signer, bob: &signer, aptos: &signer) acquires Pool, UserInfo {
        test_stake(acc, alice, bob, aptos);
        timestamp::fast_forward_seconds(400);
        withdraw_payment<USDT>(alice); // not treasury
    }



}
    
}