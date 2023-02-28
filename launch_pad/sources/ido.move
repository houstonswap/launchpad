address HoustonLaunchPad {

module ido {
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::account;
    use aptos_framework::type_info::{Self, TypeInfo};
    use std::signer;
    use std::vector;
    use aptos_framework::event::{Self, EventHandle};
    use std::timestamp;
    friend HoustonLaunchPad::whitelist_ticket;
    
    struct Pool<phantom LaunchT> has key {
        distribute_start_time: u64,
        start_time: u64,
        end_time: u64,
        
        total_subscribed_amount: u64, 
        offer_coins: Coin<LaunchT>,
        total_offer_amount: u64, 
        max_raised: u64, // overflow == 0 
        max_raised_per_user: u64,
        sale_price: u128, // price * PRICE_PRECISION 
        treasury: address,
        
        tge_percent: u64, 
        vesting_interval: u64,
        total_vesting_time: u64,
        
        accepted_tokens: vector<TypeInfo>, // idx 0 = main payment token and all tokens have the same rate
        default_decimals: u8, // decimals of 1st accepted token
        events: PoolEvents<LaunchT>
    }

    struct PaymentStore<phantom PaymentT, phantom LaunchT> has key {
        payment_coins: Coin<PaymentT>,
        withdrawn: bool
    }

    struct UserInfo<phantom LaunchT> has key {
        subscribed_amount: u64, 
        deposit_amounts: vector<u64>,
        entitled: u64,
        claimed: u64,
    }

    struct SubscribeCapability<phantom LaunchT> has store {}


    //
    // Events
    //

    struct PoolEvents<phantom LaunchT> has store {
        pool_created_events: EventHandle<PoolCreatedEvent<LaunchT>>,
        deposit_events: EventHandle<DepositEvent<LaunchT>>,
        claim_events: EventHandle<ClaimEvent<LaunchT>>,
        withdraw_payment_events: EventHandle<WithdrawPaymentEvent<LaunchT>>
    }

    struct PoolCreatedEvent<phantom LaunchT> has store, drop {
        total_distribute_amt: u64,
        max_raised: u64,
        sale_price: u128
    }

    struct DepositEvent<phantom LaunchT> has store, drop {
        user: address, 
        amount: u64,
        payment_coin: TypeInfo,
    }

    struct ClaimEvent<phantom LaunchT> has store, drop {
        user: address,
        claimed: u64
    }

    struct WithdrawPaymentEvent<phantom LaunchT> has store, drop {
        to: address,
        amount: u64,
        payment_coin: TypeInfo
    }


    //
    // Constants
    //

    const ERROR_NOT_ADMIN: u64 = 1;
    /// Pool does not exists
    const ERROR_NO_POOLS: u64 = 2;
    /// outside deposit period
    const ERROR_DEPOSIT_TIME: u64 = 3;
    // const ERROR_DISTRIBUTE_TIME: u64 = 4;
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
    /// No claimmable amount
    const ERROR_CLAIMMED: u64 = 13;
    const ERROR_VESTING_SETTING: u64 = 14;
    const ERROR_DUPLICATE_TOKENS: u64 = 15;
    /// Invalid Payment coin
    const ERROR_PAYMENT_TOKEN: u64 = 16;
    // const ERROR_ENTITLED_ZERO: u64 = 17;
    // const ERROR_USER_CAP: u64 = 18;
    /// Invalid refund amount
    const ERROR_REFUND: u64 = 19;
    const ERROR_PAYMENT_DECIMALS: u64 = 20;
    const ERROR_WITHDRAWN: u64 = 21;
    

    const EQUAL: u8 = 0;
    const LESS_THAN: u8 = 1;
    const GREATER_THAN: u8 = 2;

    const PRICE_PRECISION: u128 = 1000000000000; // 1e12
    const TGE_PERCENT_DENOM: u64 = 10000;
    
    fun assert_admin(account: &signer) {
        assert!(signer::address_of(account) == @HoustonLaunchPad, ERROR_NOT_ADMIN);
    }

    /// Create a launch pool
    entry fun create_launch<PaymentT, LaunchT>(
        admin: &signer,
        treasury: address,
        start_time: u64,
        end_time: u64,
        distribute_start: u64,
        total_offer_coins: u64,
        sale_price: u128,
        max_raised: u64, // 0 or != 0 => 0 = overflow,
        max_raised_per_user: u64
    ) acquires Pool
    {
        // checking admin, pool doesnt exists, time order, treasury account
        assert_admin(admin);
        assert!(!exists<Pool<LaunchT>>(@HoustonLaunchPad), ERROR_POOL_DUPLICATES);
        let now = timestamp::now_seconds();
        assert!(now <= start_time && start_time < end_time && end_time < distribute_start, ERROR_TIME_ORDER);
        assert!(account::exists_at(treasury), ERROR_TREASURY);

        // if overflow, max_raised = 0, else total offer / price = max raised
        if (max_raised > 0 && PRICE_PRECISION * (total_offer_coins as u128) / sale_price != (max_raised as u128)) {
            max_raised = ((PRICE_PRECISION * (total_offer_coins as u128) / sale_price) as u64);
        };

        // 1st accepted tokens = PaymentT
        let accepted_tokens = vector::empty<TypeInfo>();
        assert!(coin::is_coin_initialized<PaymentT>(), ERROR_PAYMENT_TOKEN);
        vector::push_back<TypeInfo>(&mut accepted_tokens, type_info::type_of<PaymentT>());

        move_to(admin, Pool<LaunchT>{
            distribute_start_time: distribute_start,
            start_time: start_time,
            end_time: end_time,
            offer_coins: coin::withdraw(admin, total_offer_coins), 
            total_offer_amount: total_offer_coins, 
            total_subscribed_amount: 0, 
            max_raised,
            max_raised_per_user,
            sale_price,
            treasury,
            // default tge = 100%
            tge_percent: TGE_PERCENT_DENOM, 
            vesting_interval: 0,
            total_vesting_time: 0,
            accepted_tokens,
            default_decimals: coin::decimals<PaymentT>(),

            events: PoolEvents{
                pool_created_events: account::new_event_handle<PoolCreatedEvent<LaunchT>>(admin),
                deposit_events: account::new_event_handle<DepositEvent<LaunchT>>(admin),
                claim_events: account::new_event_handle<ClaimEvent<LaunchT>>(admin),
                withdraw_payment_events: account::new_event_handle<WithdrawPaymentEvent<LaunchT>>(admin),
            }
        });
        // payment store for PaymentT in this launch
        move_to(admin, PaymentStore<PaymentT, LaunchT>{
            payment_coins: coin::zero<PaymentT>(),
            withdrawn: false

        });

        // events
        let pool = borrow_global_mut<Pool<LaunchT>>(@HoustonLaunchPad);
        let events = &mut pool.events.pool_created_events;
        event::emit_event<PoolCreatedEvent<LaunchT>>(
            events,
            PoolCreatedEvent<LaunchT> {
                total_distribute_amt: total_offer_coins,
                max_raised,
                sale_price
            }
        );
    }

    /// add vesting time schedule to ido, only when ido has not started
    entry fun add_vesting<LaunchT>(
        admin: &signer,
        tge_percent: u64, // max TGE_PERCENT_DENOM
        vesting_interval: u64, // interval must be > total vesting time
        total_vesting_time: u64
    ) acquires Pool
    {
        // checking admin, pool exists, sensible numbers, ido has not started
        assert_admin(admin);
        assert!(exists<Pool<LaunchT>>(@HoustonLaunchPad), ERROR_NO_POOLS);
        assert!(tge_percent < TGE_PERCENT_DENOM, ERROR_VESTING_SETTING);
        assert!(total_vesting_time >= vesting_interval, ERROR_VESTING_SETTING);
        assert!(!is_ido_started<LaunchT>(), ERROR_TIME_ORDER);

        // set values to pool
        let pool = borrow_global_mut<Pool<LaunchT>>(@HoustonLaunchPad);
        pool.tge_percent = tge_percent;
        pool.vesting_interval = vesting_interval;
        pool.total_vesting_time = total_vesting_time;
    }

    /// add additional payment_tokens time schedule to ido, only when ido has not started
    entry fun add_payment_tokens<PaymentT, LaunchT>(admin: &signer) acquires Pool
    {
        // checking admin, pool exists, payment store does not exists, ido not started 
        assert_admin(admin);
        assert!(exists<Pool<LaunchT>>(@HoustonLaunchPad), ERROR_NO_POOLS);
        assert!(!exists<PaymentStore<PaymentT, LaunchT>>(@HoustonLaunchPad), ERROR_DUPLICATE_TOKENS);
        assert!(!is_ido_started<LaunchT>(), ERROR_TIME_ORDER);

        // add new paymentT to accepted_tokens and create payment store
        let pool = borrow_global_mut<Pool<LaunchT>>(@HoustonLaunchPad);
        assert!(coin::decimals<PaymentT>() == pool.default_decimals, ERROR_PAYMENT_DECIMALS); 
        let type = type_info::type_of<PaymentT>();
        vector::push_back(&mut pool.accepted_tokens, type);
        
        move_to(admin, PaymentStore<PaymentT, LaunchT>{
            payment_coins: coin::zero<PaymentT>(),
            withdrawn: false
        });
    }

    /// let other modules control the cap per users
    public(friend) fun request_cap<LaunchT>(admin: &signer): SubscribeCapability<LaunchT> {
        assert_admin(admin);
        assert!(exists<Pool<LaunchT>>(@HoustonLaunchPad), ERROR_NO_POOLS);

        SubscribeCapability<LaunchT>{}

    }

    /// check if ido started
    public(friend) fun is_ido_started<LaunchT>(): bool acquires Pool {
        if(exists<Pool<LaunchT>>(@HoustonLaunchPad))
            timestamp::now_seconds() >= borrow_global<Pool<LaunchT>>(@HoustonLaunchPad).start_time 
        else false
    }

    /// deposit payment tokens to participate the sale
    entry fun deposit<PaymentT, LaunchT>(account: &signer, amount: u64) acquires UserInfo, Pool, PaymentStore
    {
        // Check pool exists, payment token registered,  
        assert!(exists<Pool<LaunchT>>(@HoustonLaunchPad), ERROR_NO_POOLS);
        assert!(exists<PaymentStore<PaymentT, LaunchT>>(@HoustonLaunchPad), ERROR_PAYMENT_TOKEN);
        let pool = borrow_global_mut<Pool<LaunchT>>(@HoustonLaunchPad);
        let max_per_user = pool.max_raised_per_user; 
        // deposit 
        assert!(max_per_user >= deposit_internal<PaymentT, LaunchT>(account, amount, pool), ERROR_CAP);
    }

    /// deposit payment tokens 
    fun deposit_internal<PaymentT, LaunchT>(account: &signer, amount: u64, pool: &mut Pool<LaunchT>): u64 acquires UserInfo, PaymentStore
    {   
        // check time order, max_raised
        let now = timestamp::now_seconds();
        assert!(now >= pool.start_time && now <= pool.end_time, ERROR_DEPOSIT_TIME);
        assert!(pool.max_raised == 0 || pool.max_raised > pool.total_subscribed_amount, ERROR_CAP);
        
        // check amount and change amount for non-overflow ido
        if(pool.max_raised > 0 && pool.max_raised - pool.total_subscribed_amount < amount) {
            amount = pool.max_raised - pool.total_subscribed_amount;
        }; 

        let final_amount = amount;
        pool.total_subscribed_amount = pool.total_subscribed_amount + amount; 
        
        let acc_addr = signer::address_of(account);
        let withdraw_amt = coin::withdraw<PaymentT>(account, amount);
        let payment_store = borrow_global_mut<PaymentStore<PaymentT, LaunchT>>(@HoustonLaunchPad);
        coin::merge<PaymentT>(&mut payment_store.payment_coins, withdraw_amt);
        let payment_idx = get_paymentT_idx<PaymentT>(&pool.accepted_tokens);
        
        
        // new deposit
        if(!exists<UserInfo<LaunchT>>(acc_addr)){
            let deposit_amounts = init_deposit_amounts(&pool.accepted_tokens);
            let original = vector::borrow_mut(&mut deposit_amounts, payment_idx);
            *original = amount;
            move_to(account, UserInfo<LaunchT>{
                subscribed_amount: amount, 
                deposit_amounts,
                // only store entitled after end time for overflow case
                entitled: if(pool.max_raised > 0) ((pool.sale_price * (amount as u128) / PRICE_PRECISION) as u64) else 0, 
                claimed: 0,
            });
        }
        // old deposit
        else {
            let info = borrow_global_mut<UserInfo<LaunchT>>(acc_addr);
            info.subscribed_amount = info.subscribed_amount + amount;
            final_amount = info.subscribed_amount;
            let original = vector::borrow_mut(&mut info.deposit_amounts, payment_idx);
            *original = *original + amount;
            info.entitled = if(pool.max_raised > 0) ((pool.sale_price * (info.subscribed_amount as u128) / PRICE_PRECISION) as u64) else 0;
        };
        
        // generate events
        let events = &mut pool.events.deposit_events;
        event::emit_event<DepositEvent<LaunchT>>(
            events,
            DepositEvent<LaunchT> {
                user: acc_addr, 
                amount,
                payment_coin: type_info::type_of<PaymentT>()
            }
        );
        // final amount = info.subscribed_amount
        final_amount
        
    }

    fun get_paymentT_idx<PaymentT>(tokens_arr: &vector<TypeInfo>): u64 {
        let i = 0;
        while(i < vector::length(tokens_arr)) {
            let type = vector::borrow(tokens_arr, i);
            if(type_info::type_of<PaymentT>() == *type) {
                return i
            };
            i = i + 1;
        };
        abort ERROR_PAYMENT_TOKEN
    }

    fun init_deposit_amounts(tokens_arr: &vector<TypeInfo>): vector<u64> {
        let arr = vector::empty<u64>();
        let i = 0;
        while(i < vector::length(tokens_arr)) {
            vector::push_back(&mut arr, 0);
            i = i + 1;
        };
        arr
    }

    /// deposit call from modules with SubscribeCapability, max_raised_per_user checking is transferred to that other module
    public(friend) fun deposit_with_cap<PaymentT, LaunchT>(account: &signer, amount: u64, _cap:&SubscribeCapability<LaunchT>): u64 acquires UserInfo, Pool, PaymentStore
    {
        assert!(exists<Pool<LaunchT>>(@HoustonLaunchPad), ERROR_NO_POOLS);
        assert!(exists<PaymentStore<PaymentT, LaunchT>>(@HoustonLaunchPad), ERROR_PAYMENT_TOKEN);
        deposit_internal<PaymentT, LaunchT>(account, amount, borrow_global_mut<Pool<LaunchT>>(@HoustonLaunchPad))
    }

    /// Claim offering coins after distribution started
    entry fun claim<PaymentT, LaunchT>(account: &signer) acquires UserInfo, Pool, PaymentStore {
        // Check pool, paymentT, time, user has deposit
        assert!(exists<Pool<LaunchT>>(@HoustonLaunchPad), ERROR_NO_POOLS);
        assert!(exists<PaymentStore<PaymentT, LaunchT>>(@HoustonLaunchPad), ERROR_PAYMENT_TOKEN);
        let pool = borrow_global_mut<Pool<LaunchT>>(@HoustonLaunchPad);
        let now = timestamp::now_seconds();
        assert!(pool.distribute_start_time <= now , ERROR_CLAIM_TIME);
        let user = signer::address_of(account);
        assert!(exists<UserInfo<LaunchT>>(user), ERROR_NO_DEPOSIT);
        
        let user_info = borrow_global_mut<UserInfo<LaunchT>>(user);
        let pool = borrow_global_mut<Pool<LaunchT>>(@HoustonLaunchPad); 
        
        // if ido over subscribed, overflow entitled amount < non_overflow amount => need refund
        let (overflow, non_overflow) = get_entitled_amounts<LaunchT>(freeze(pool), user_info.subscribed_amount);
        if(overflow < non_overflow) {
            // should not happen, just in case.
            if(!coin::is_account_registered<PaymentT>(user)) {
                coin::register<LaunchT>(account);
            };
            let paymentT_idx = get_paymentT_idx<PaymentT>(&pool.accepted_tokens);
            let deposited = vector::borrow_mut(&mut user_info.deposit_amounts, paymentT_idx);
            if(*deposited > 0) {
                let refund = refund<PaymentT, LaunchT>(non_overflow - overflow, pool.sale_price, *deposited, user_info.subscribed_amount);
                assert!(*deposited > coin::value(&refund), ERROR_REFUND);
                coin::deposit<PaymentT>(user, refund);
            };
            *deposited = 0;
        };
        if(user_info.entitled == 0) {
            user_info.entitled = if(overflow < non_overflow) overflow else non_overflow;
        };
        
        // claimable based on vesting schedule and entitled amount
        let claimableAmt = get_claimable_amount<LaunchT>(freeze(pool), user_info.entitled, user_info.claimed, now);
        if(claimableAmt > 0) {
            user_info.claimed = user_info.claimed + claimableAmt;
        
            // make sure user able to receive coin
            if(!coin::is_account_registered<LaunchT>(user)) {
                coin::register<LaunchT>(account);
            };

            // send coins to user
            let tokens_claimable = coin::extract(&mut pool.offer_coins, claimableAmt);
            coin::deposit<LaunchT>(user, tokens_claimable);
        
            // write event
            let events = &mut pool.events.claim_events;
            event::emit_event<ClaimEvent<LaunchT>>(
                events,
                ClaimEvent<LaunchT> {
                    user, 
                    claimed: claimableAmt
                }
            );
        };
    }

    /// refund paymentT to user if overflow
    fun refund<PaymentT, LaunchT>(refundable: u64, price: u128,  deposited: u64, subscribed: u64): Coin<PaymentT> acquires PaymentStore {
        let store = borrow_global_mut<PaymentStore<PaymentT, LaunchT>>(@HoustonLaunchPad);
        let refund = (refundable as u128) * PRICE_PRECISION / price *  (deposited as u128) / (subscribed as u128);
        coin::extract(&mut store.payment_coins, (refund as u64))
    }

    /// get entitled based on overflow / non- overflow situations
    fun get_entitled_amounts<LaunchT>(pool: &Pool<LaunchT>, amount: u64): (u64, u64) { // overflow, non - overflow
        let non_overflow = ((pool.sale_price * (amount as u128) / PRICE_PRECISION) as u64);
        if(pool.max_raised > 0) {
            (non_overflow , non_overflow)
        }else {
            (((pool.total_offer_amount as u128) * (amount as u128) / (pool.total_subscribed_amount as u128) as u64) , non_overflow)
        }
    }

    /// get claimable amount based on entitled + vesting schedule + claimed amount
    fun get_claimable_amount<LaunchT>(pool: &Pool<LaunchT>, entitled: u64, claimed: u64, now: u64): u64{
        if(entitled == 0 || now < pool.distribute_start_time) {
            0
        } else if(pool.tge_percent == TGE_PERCENT_DENOM) {
            entitled - claimed
        }else {
            let num_interval = (now - pool.distribute_start_time) / pool.vesting_interval;
            let tge_amount = entitled * pool.tge_percent / TGE_PERCENT_DENOM; 
            let left = entitled - tge_amount;
            let vesting_time_passed = 
                if (pool.total_vesting_time > num_interval * pool.vesting_interval) 
                    num_interval * pool.vesting_interval
                else pool.total_vesting_time; 
            
            tge_amount + (((left as u128) * (vesting_time_passed as u128) / (pool.total_vesting_time as u128)) as u64) - claimed
        }
    }

    /// admin withdraw payment coins, only after end time
    entry fun withdraw_payment<PaymentT, LaunchT>(treasury: &signer) acquires Pool, PaymentStore
    {   
        // check pool and payment store exists
        assert!(exists<Pool<LaunchT>>(@HoustonLaunchPad), ERROR_NO_POOLS);
        assert!(exists<PaymentStore<PaymentT, LaunchT>>(@HoustonLaunchPad), ERROR_NO_POOLS);

        let pool = borrow_global_mut<Pool<LaunchT>>(@HoustonLaunchPad);
        let payment_store = borrow_global_mut<PaymentStore<PaymentT, LaunchT>>(@HoustonLaunchPad);
        assert!(!payment_store.withdrawn, ERROR_WITHDRAWN);
        
        // check treasury
        assert!(signer::address_of(treasury) == pool.treasury, ERROR_TREASURY);
        // make sure treasury register for paymentT
        if(!coin::is_account_registered<PaymentT>(pool.treasury)) {
            coin::register<PaymentT>(treasury);
        };

        // check time order
        let now = timestamp::now_seconds();
        assert!(pool.end_time < now, ERROR_WITHDRAW_PAYMENT_TIME);

        // check amount
        let amount = 
            if (pool.max_raised > 0 ) { // no overflow
                coin::value<PaymentT>(&payment_store.payment_coins)
            }else {
                // need to save some paymentT for overflow refund
                let total_stored = coin::value<PaymentT>(&payment_store.payment_coins);
                let offer_amount_in_payment = (pool.total_offer_amount as u128) * (total_stored as u128) / (pool.total_subscribed_amount as u128) ;
                let allowed = ((offer_amount_in_payment * PRICE_PRECISION / pool.sale_price) as u64);
                // if no overflow, can withdraw all payment
                if (total_stored > allowed) allowed else total_stored
            };
        
        *&mut payment_store.withdrawn = true;
        assert!(amount > 0, ERROR_WITHDRAW_ZERO_AMT);

        // make sure user can receive payment coin
        if(!coin::is_account_registered<PaymentT>(pool.treasury)) {
            coin::register<PaymentT>(treasury);
        };

        // transfer the payment
        coin::deposit<PaymentT>(pool.treasury, coin::extract<PaymentT>(&mut payment_store.payment_coins, amount));
        // write event
        event::emit_event<WithdrawPaymentEvent<LaunchT>>(
            &mut pool.events.withdraw_payment_events,
            WithdrawPaymentEvent<LaunchT> {
                to: pool.treasury,
                amount,
                payment_coin: type_info::type_of<PaymentT>()
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
    use HoustonDevTools::dev::{Self, ETH, USDT, DAI, ABC};
        
        
    #[test_only]
    public fun create_launch_for_test_usdt_eth(acc: &signer) acquires Pool {
        // 1. launch
        let now = timestamp::now_seconds();
        create_launch<USDT, ETH>(
            acc, 
            signer::address_of(acc), 
            now + 100, //start
            now + 200, //end
            now + 300, // distribute
            1000000, // total offer
            10000, // sale price
            0, //max
            100 //max per user
        );
    }

    #[test(acc=@HoustonLaunchPad)]
    fun test_launch_overflow(acc: &signer) acquires Pool{
        let addr = signer::address_of(acc);
        // 1. launch
        dev::setup();
        dev::create_account_for_test(acc);
        dev::initialize_coins(acc);
        dev::register_coins(acc);
        let amount = 1000000000000; //10000E8
        coin::deposit<ETH>(addr, dev::mint_for_test<ETH>(acc, amount));
        let now = timestamp::now_seconds();
        
        create_launch<USDT, ETH>(
            acc, 
            signer::address_of(acc), 
            now + 100, //start
            now + 200, //end
            now + 300, // distribute
            amount, // total offer
            1000000000, // sale price
            0, //max
            100000 //max per user
        );

        let pool = borrow_global<Pool<ETH>>(addr);
        assert!(pool.distribute_start_time == now + 300, 0);
        assert!(pool.start_time == now + 100, 0);
        assert!(pool.end_time == now + 200, 0);
        assert!(pool.total_subscribed_amount == 0, 0);
        assert!(coin::value(&pool.offer_coins) == amount, 0);
        assert!(pool.total_offer_amount == amount, 0);
        assert!(pool.max_raised == 0, 0);
        assert!(pool.max_raised_per_user == 100000, 0);
        assert!(pool.sale_price == 1000000000, 0);
        assert!(pool.treasury == addr, 0);
        assert!(pool.tge_percent == TGE_PERCENT_DENOM, 0);
        assert!(pool.vesting_interval == 0, 0);
        assert!(pool.total_vesting_time == 0, 0);
        assert!(vector::length(&pool.accepted_tokens) == 1, 0);
        let token = *vector::borrow(&pool.accepted_tokens, 0);
        assert!(token == type_info::type_of<USDT>(), 0);
        assert!(!is_ido_started<ETH>(), 0);
        assert!(!is_ido_started<DAI>(), 0);
        
        
    }

    #[test(acc=@HoustonLaunchPad)]
    #[expected_failure(abort_code = 6, location = Self)]
    fun test_launch_fail_time_0(acc: &signer) acquires Pool{
        // 0. setup
        let addr = signer::address_of(acc);
        // 1. launch
        dev::setup();
        dev::create_account_for_test(acc);
        dev::initialize_coins(acc);
        dev::register_coins(acc);
        let amount = 1000000000000; //10000E8
        coin::deposit<ETH>(addr, dev::mint_for_test<ETH>(acc, amount));
        
        let now = timestamp::now_seconds();
        
        // deposit end time < deposit start time
        create_launch<USDT, ETH>(
            acc, 
            signer::address_of(acc), 
            now + 100, 
            now + 50, 
            now + 300, 
            amount, // total offer
            10000, // sale price
            0, //max
            100 //max per user
        );
    }

    #[test(acc=@HoustonLaunchPad)]
    #[expected_failure(abort_code = 6, location = Self)]
    fun test_launch_fail_time_1(acc: &signer) acquires Pool{
        dev::setup();
        dev::create_account_for_test(acc);
        dev::initialize_coins(acc);
        dev::register_coins(acc);
        let addr = signer::address_of(acc);
        
        let amount = 1000000000000; //10000E8
        coin::deposit<ETH>(addr, dev::mint_for_test<ETH>(acc, amount));
        
        // deposit end time ==  distribute time
        create_launch<USDT, ETH>(acc, signer::address_of(acc), 100, 200, 200, 
            amount, // total offer
            10000, // sale price
            0, //max
            100 //max per user
        );
    }

    #[test(acc=@HoustonLaunchPad)]
    #[expected_failure(abort_code = 6, location = Self)]
    fun test_launch_fail_time_2(acc: &signer) acquires Pool{
        dev::setup();
        dev::create_account_for_test(acc);
        dev::initialize_coins(acc);
        dev::register_coins(acc);
        let addr = signer::address_of(acc);
        let amount = 1000000000000; //10000E8
        coin::deposit<ETH>(addr, dev::mint_for_test<ETH>(acc, amount));
        timestamp::fast_forward_seconds(100);
        // start time < now
        create_launch<USDT, ETH>(acc, signer::address_of(acc), 80, 200, 300, 1000000, 10000, 0, 1000);
    }

    #[test(acc=@HoustonLaunchPad)]
    #[expected_failure(abort_code = 5, location = Self)]
    fun test_launch_fail_duplicate(acc: &signer) acquires Pool{
        dev::setup();
        dev::create_account_for_test(acc);
        dev::initialize_coins(acc);
        dev::register_coins(acc);
        let addr = signer::address_of(acc);
        let amount = 1000000000000; //10000E8
        coin::deposit<ETH>(addr, dev::mint_for_test<ETH>(acc, amount));
        timestamp::fast_forward_seconds(100);
        // start time < now
        create_launch<USDT, ETH>(acc, signer::address_of(acc), 110, 200, 300, 1000000, 10000, 0, 1000);
        create_launch<DAI, ETH>(acc, signer::address_of(acc), 110, 200, 300, 1000000, 10000, 0, 1000);
    }

    #[test(acc=@HoustonLaunchPad)]
    #[expected_failure(abort_code = 16, location = Self)]
    fun test_launch_fail_payment(acc: &signer) acquires Pool{
        dev::setup();
        dev::create_account_for_test(acc);
        // dev::initialize_coins(acc);
        // dev::register_coins(acc);
        // let amount = 1000000000000; //10000E8
        // coin::deposit<ETH>(addr, dev::mint_for_test<ETH>(acc, amount));
        timestamp::fast_forward_seconds(100);
        // start time < now
        create_launch<USDT, ETH>(acc, signer::address_of(acc), 110, 200, 300, 1000000, 10000, 0, 1000);
        // create_launch<DAI, ETH>(acc, signer::address_of(acc), 110, 200, 300, 1000000, 10000, 0, 1000);
    }

    #[test(acc=@HoustonLaunchPad)]
    fun test_add_vesting(acc: &signer) acquires Pool{
        let addr = signer::address_of(acc);
        test_launch_overflow(acc);
        // vesting 50% for 4 months with 1 month interval
        add_vesting<ETH>(acc, TGE_PERCENT_DENOM / 2, 86400 * 30, 86400 * 120);
        let pool = borrow_global<Pool<ETH>>(addr);

        assert!(pool.tge_percent == TGE_PERCENT_DENOM / 2, 0);
        assert!(pool.vesting_interval == 86400 * 30, 0);
        assert!(pool.total_vesting_time == 86400 * 120, 0);

        timestamp::fast_forward_seconds(100);
        assert!(is_ido_started<ETH>(), 0);

        
    }
    #[test(acc=@HoustonLaunchPad)]
    #[expected_failure(abort_code = 2, location = Self)]
    fun test_add_vesting_fail_no_pools(acc: &signer) acquires Pool{
        add_vesting<ETH>(acc, TGE_PERCENT_DENOM / 2, 86400 * 30, 86400 * 120);
    }

    #[test(acc=@HoustonLaunchPad)]
    #[expected_failure(abort_code = 14, location = Self)]
    fun test_add_vesting_fail_setting(acc: &signer) acquires Pool{
        test_launch_overflow(acc);
        add_vesting<ETH>(acc, TGE_PERCENT_DENOM, 86400 * 30, 86400 * 120);
    }

    #[test(acc=@HoustonLaunchPad)]
    #[expected_failure(abort_code = 14, location = Self)]
    fun test_add_vesting_fail_setting_2(acc: &signer) acquires Pool{
        test_launch_overflow(acc);
        add_vesting<ETH>(acc, TGE_PERCENT_DENOM - 1, 86400 * 30, 86400 * 30 - 1);
    }

    #[test(acc=@HoustonLaunchPad)]
    fun test_add_payment_tokens(acc: &signer) acquires Pool{
        let addr = signer::address_of(acc);
        test_launch_overflow(acc);
        add_payment_tokens<ABC, ETH>(acc);
        let pool = borrow_global<Pool<ETH>>(addr);

        assert!(vector::length(&pool.accepted_tokens) == 2, 0);
        let (_b, idx) = vector::index_of(&pool.accepted_tokens, &type_info::type_of<ABC>());
        assert!( idx == 1, 0);
        assert!(exists<PaymentStore<ABC, ETH>>(addr), 0);
        
    }

    #[test(acc=@HoustonLaunchPad)]
    #[expected_failure(abort_code = 15, location = Self)]
    fun test_add_payment_tokens_fail_dup(acc: &signer) acquires Pool{
        test_launch_overflow(acc);
        add_payment_tokens<USDT, ETH>(acc);
    }

    #[test(acc=@HoustonLaunchPad)]
    #[expected_failure(abort_code = 6, location = Self)]
    fun test_add_payment_tokens_fail_time(acc: &signer) acquires Pool{
        test_launch_overflow(acc);
        timestamp::fast_forward_seconds(110);
        add_payment_tokens<DAI, ETH>(acc);
    }

    #[test(acc=@HoustonLaunchPad)]
    fun test_request_cap(acc: &signer) acquires Pool{
        test_launch_overflow(acc);
        let SubscribeCapability<ETH>{} = request_cap<ETH>(acc);
    }

    #[test(acc=@HoustonLaunchPad, alice=@0xA11CE, bob=@0xB0B)]
    fun test_stake_overflow(acc: &signer, alice: &signer, bob: &signer) acquires Pool, PaymentStore, UserInfo {
        let addr = signer::address_of(acc);
        // 1. launch
        dev::setup();
        dev::create_account_for_test(acc);
        dev::initialize_coins(acc);
        dev::register_coins(acc);
        let amount = 1000000000000; //10000E8
        coin::deposit<ETH>(addr, dev::mint_for_test<ETH>(acc, amount));
        let now = timestamp::now_seconds();
        
        create_launch<USDT, ETH>(
            acc, 
            signer::address_of(acc), 
            now + 100, //start
            now + 200, //end
            now + 300, // distribute
            amount, // total offer
            1000000000000000, // sale price
            0, //max
            amount * 3 //max per user
        );

        dev::create_account_for_test(alice);
        dev::register_coins(alice);
        let alice_addr = signer::address_of(alice);
        coin::deposit<USDT>(alice_addr, dev::mint_for_test<USDT>(acc, amount));
        
        dev::create_account_for_test(bob);
        dev::register_coins(bob);
        let bob_addr = signer::address_of(bob);
        coin::deposit<USDT>(bob_addr, dev::mint_for_test<USDT>(acc, amount));
        
        // 1. alice deposit
        timestamp::fast_forward_seconds(100);
        let init_usdt = coin::balance<USDT>(alice_addr);
        deposit<USDT, ETH>(alice, amount);
        
        let aft_usdt = coin::balance<USDT>(alice_addr);
        
        let userInfo = borrow_global<UserInfo<ETH>>(alice_addr);
        assert!(vector::length(&userInfo.deposit_amounts) == 1, 0);
        assert!(*vector::borrow(&userInfo.deposit_amounts, 0) == amount, 0);

        assert!(userInfo.subscribed_amount == amount, 0);
        assert!(init_usdt - aft_usdt == amount, 0);
        // let pool = borrow_global<Pool<USDT>>(signer::address_of(acc));
        let payment_store = borrow_global<PaymentStore<USDT, ETH>>(signer::address_of(acc));
        let total_amount_in = coin::value<USDT>(&payment_store.payment_coins);
        assert!(total_amount_in == userInfo.subscribed_amount, 0);
        assert!(userInfo.entitled == 0, 0);
        
        // 2. bob deposit
        timestamp::fast_forward_seconds(10);
        let bob_addr = signer::address_of(bob);
        let init_usdt_b = coin::balance<USDT>(bob_addr);
        deposit<USDT, ETH>(bob, amount);
        let aft_usdt_b = coin::balance<USDT>(bob_addr);
        
        let userInfo = borrow_global<UserInfo<ETH>>(bob_addr);
        assert!(userInfo.subscribed_amount == amount, 0);
        assert!(init_usdt_b - aft_usdt_b == amount, 0);
        assert!(vector::length(&userInfo.deposit_amounts) == 1, 0);
        assert!(*vector::borrow(&userInfo.deposit_amounts, 0) == amount, 0);
        let payment_store = borrow_global<PaymentStore<USDT, ETH>>(signer::address_of(acc));
        let pool = borrow_global<Pool<ETH>>(signer::address_of(acc));
        assert!(coin::value<USDT>(&payment_store.payment_coins) == pool.total_subscribed_amount, 0);
    }

    

    #[test(acc=@HoustonLaunchPad, alice=@0xA11CE, bob=@0xB0B)]
    fun test_stake_overflow_2_times(acc: &signer, alice: &signer, bob: &signer) acquires Pool, PaymentStore, UserInfo {
        test_stake_overflow(acc, alice, bob);
        let amount = 1000000000000; //10000E8
        let alice_addr = signer::address_of(alice);
        // 3. alice deposit one more time
        coin::deposit<USDT>(alice_addr, dev::mint_for_test<USDT>(acc, amount));
        deposit<USDT, ETH>(alice, amount);
        
        let userInfo = borrow_global<UserInfo<ETH>>(alice_addr);
        assert!(vector::length(&userInfo.deposit_amounts) == 1, 0);
        assert!(*vector::borrow(&userInfo.deposit_amounts, 0) == amount * 2, 0);

        assert!(userInfo.subscribed_amount == amount * 2, 0);
    }

     

    #[test(acc=@HoustonLaunchPad, alice=@0xA11CE, bob=@0xB0B)]
    fun test_stake_overflow_2_tokens(acc: &signer, alice: &signer, bob: &signer) acquires Pool, PaymentStore, UserInfo {
        let addr = signer::address_of(acc);
        // 1. launch
        dev::setup();
        dev::create_account_for_test(acc);
        dev::initialize_coins(acc);
        dev::register_coins(acc);
        let amount = 1000000000000; //10000E8
        coin::deposit<ETH>(addr, dev::mint_for_test<ETH>(acc, amount));
        let now = timestamp::now_seconds();
        
        create_launch<USDT, ETH>(
            acc, 
            signer::address_of(acc), 
            now + 100, //start
            now + 200, //end
            now + 300, // distribute
            amount, // total offer
            1000000000000000, // sale price
            0, //max
            amount * 3 //max per user
        );

        add_payment_tokens<ABC, ETH>(acc);
        
        dev::create_account_for_test(alice);
        dev::register_coins(alice);
        let alice_addr = signer::address_of(alice);
        coin::deposit<USDT>(alice_addr, dev::mint_for_test<USDT>(acc, amount));
        coin::deposit<ABC>(alice_addr, dev::mint_for_test<ABC>(acc, amount));
        
        dev::create_account_for_test(bob);
        dev::register_coins(bob);
        let bob_addr = signer::address_of(bob);
        coin::deposit<USDT>(bob_addr, dev::mint_for_test<USDT>(acc, amount));
        
        // 1. alice deposit
        timestamp::fast_forward_seconds(100);
        deposit<USDT, ETH>(alice, amount);
        
        let userInfo = borrow_global<UserInfo<ETH>>(alice_addr);
        assert!(vector::length(&userInfo.deposit_amounts) == 2, 0);
        assert!(*vector::borrow(&userInfo.deposit_amounts, 0) == amount, 0);

        assert!(userInfo.subscribed_amount == amount, 0);
        // let pool = borrow_global<Pool<USDT>>(signer::address_of(acc));
        let payment_store = borrow_global<PaymentStore<USDT, ETH>>(signer::address_of(acc));
        let total_amount_in = coin::value<USDT>(&payment_store.payment_coins);
        assert!(total_amount_in == userInfo.subscribed_amount, 0);
        assert!(userInfo.entitled == 0, 0);
        
        // 2. bob deposit
        timestamp::fast_forward_seconds(10);
        let bob_addr = signer::address_of(bob);
        let init_usdt_b = coin::balance<USDT>(bob_addr);
        deposit<USDT, ETH>(bob, amount);
        let aft_usdt_b = coin::balance<USDT>(bob_addr);
        
        let userInfo = borrow_global<UserInfo<ETH>>(bob_addr);
        assert!(userInfo.subscribed_amount == amount, 0);
        assert!(init_usdt_b - aft_usdt_b == amount, 0);
        assert!(vector::length(&userInfo.deposit_amounts) == 2, 0);
        assert!(*vector::borrow(&userInfo.deposit_amounts, 0) == amount, 0);
        let payment_store = borrow_global<PaymentStore<USDT, ETH>>(signer::address_of(acc));
        let pool = borrow_global<Pool<ETH>>(signer::address_of(acc));
        assert!(coin::value<USDT>(&payment_store.payment_coins) == pool.total_subscribed_amount, 0);
        
        let amount = 1000000000000; //10000E8
        let alice_addr = signer::address_of(alice);
        // 3. alice deposit one more time
        deposit<ABC, ETH>(alice, amount);
        
        let userInfo = borrow_global<UserInfo<ETH>>(alice_addr);
        assert!(vector::length(&userInfo.deposit_amounts) == 2, 0);
        assert!(*vector::borrow(&userInfo.deposit_amounts, 1) == amount, 0);

        assert!(userInfo.subscribed_amount == amount * 2, 0);
        let payment_store = borrow_global<PaymentStore<ABC, ETH>>(signer::address_of(acc));
        let total_amount_in = coin::value<ABC>(&payment_store.payment_coins);
        assert!(total_amount_in == userInfo.subscribed_amount / 2, 0);
        assert!(userInfo.entitled == 0, 0);
        let pool = borrow_global<Pool<ETH>>(signer::address_of(acc));
        assert!(pool.total_subscribed_amount == amount * 3, 0);
    }

    #[test(acc=@HoustonLaunchPad, alice=@0xA11CE, bob=@0xB0B)]
    fun test_stake_no_overflow(acc: &signer, alice: &signer, bob: &signer) acquires Pool, PaymentStore, UserInfo {
        // 1. launch
        let addr = signer::address_of(acc);
        
        dev::setup();
        dev::create_account_for_test(acc);
        dev::initialize_coins(acc);
        dev::register_coins(acc);
        let amount = 1000000000000; //10000E8
        coin::deposit<ETH>(addr, dev::mint_for_test<ETH>(acc, amount));
        let now = timestamp::now_seconds();
        
        create_launch<USDT, ETH>(
            acc, 
            signer::address_of(acc), 
            now + 100, //start
            now + 200, //end
            now + 300, // distribute
            amount, // total offer
            1000000000000000, // sale price
            ((1000000000 * (amount as u128) / PRICE_PRECISION) as u64), //max
            amount //max per user
        );
        let pool = borrow_global<Pool<ETH>>(addr);
        let price = pool.sale_price;
        let max = pool.max_raised;

        dev::create_account_for_test(alice);
        dev::register_coins(alice);
        let alice_addr = signer::address_of(alice);
        coin::deposit<USDT>(alice_addr, dev::mint_for_test<USDT>(acc, (max as u64)));
        
        dev::create_account_for_test(bob);
        dev::register_coins(bob);
        let bob_addr = signer::address_of(bob);
        coin::deposit<USDT>(bob_addr, dev::mint_for_test<USDT>(acc, (max as u64)));
        
        // 1. alice deposit
        timestamp::fast_forward_seconds(100);
        
        let init_usdt = coin::balance<USDT>(alice_addr);
        deposit<USDT, ETH>(alice, max / 2);
        
        let aft_usdt = coin::balance<USDT>(alice_addr);
        
        let userInfo = borrow_global<UserInfo<ETH>>(alice_addr);
        assert!(userInfo.subscribed_amount == max / 2, 0);
        assert!(init_usdt - aft_usdt == max / 2, 0);
        // let pool = borrow_global<Pool<USDT>>(signer::address_of(acc));
        let payment_store = borrow_global<PaymentStore<USDT, ETH>>(signer::address_of(acc));
        let total_amount_in = coin::value<USDT>(&payment_store.payment_coins);
        assert!(total_amount_in == userInfo.subscribed_amount, 0);
        assert!(userInfo.entitled == ((price * (userInfo.subscribed_amount as u128) / PRICE_PRECISION) as u64), 0);
        assert!(userInfo.entitled > 0, 0);
        
        // 2. bob deposit
        timestamp::fast_forward_seconds(10);
        let bob_addr = signer::address_of(bob);
        let init_usdt_b = coin::balance<USDT>(bob_addr);
        deposit<USDT, ETH>(bob, max);
        let aft_usdt_b = coin::balance<USDT>(bob_addr);
        
        let userInfo = borrow_global<UserInfo<ETH>>(bob_addr);
        assert!(userInfo.subscribed_amount == max / 2, 0); // only subscribe for max / 2
        assert!(init_usdt_b - aft_usdt_b == max / 2, 0);
        let payment_store = borrow_global<PaymentStore<USDT, ETH>>(signer::address_of(acc));
        let pool = borrow_global<Pool<ETH>>(signer::address_of(acc));
        assert!(coin::value<USDT>(&payment_store.payment_coins) == pool.total_subscribed_amount, 0);
        
    }

    #[test(acc=@HoustonLaunchPad, alice=@0xA11CE)]
    #[expected_failure(abort_code = 7, location = Self)]
    fun test_stake_fail_max_per_user(acc: &signer, alice: &signer) acquires Pool, PaymentStore, UserInfo {
        let addr = signer::address_of(acc);
        // 1. launch
        test_launch_overflow(acc);
        let pool = borrow_global<Pool<ETH>>(addr);
        let max_per_user = pool.max_raised_per_user;

        dev::create_account_for_test(alice);
        dev::register_coins(alice);
        let alice_addr = signer::address_of(alice);
        coin::deposit<USDT>(alice_addr, dev::mint_for_test<USDT>(acc, max_per_user + 1));
        
       
        // 1. alice deposit
        timestamp::fast_forward_seconds(100);
        deposit<USDT, ETH>(alice, max_per_user + 1);
        
    }

    #[test(acc=@HoustonLaunchPad, alice=@0xA11CE)]
    #[expected_failure(abort_code = 3, location = Self)]
    fun test_stake_fail_time_1(acc: &signer, alice: &signer) acquires Pool, PaymentStore, UserInfo {
        let addr = signer::address_of(acc);
        // 1. launch
        test_launch_overflow(acc);
        let pool = borrow_global<Pool<ETH>>(addr);
        let max_per_user = pool.max_raised_per_user;

        dev::create_account_for_test(alice);
        dev::register_coins(alice);
        let alice_addr = signer::address_of(alice);
        coin::deposit<USDT>(alice_addr, dev::mint_for_test<USDT>(acc, max_per_user + 1));
        
       
        // 1. alice deposit
        // timestamp::fast_forward_seconds(100);
        deposit<USDT, ETH>(alice, max_per_user);
        
    }

    #[test(acc=@HoustonLaunchPad, alice=@0xA11CE, bob=@0xB0B)]
    #[expected_failure(abort_code = 7, location = Self)]
    fun test_stake_no_overflow_fail_cap_over(acc: &signer, alice: &signer, bob: &signer) acquires Pool, PaymentStore, UserInfo {
        let addr = signer::address_of(acc);
        // 1. launch
        dev::setup();
        dev::create_account_for_test(acc);
        dev::initialize_coins(acc);
        dev::register_coins(acc);
        let amount = 1000000000000; //10000E8
        coin::deposit<ETH>(addr, dev::mint_for_test<ETH>(acc, amount));
        let now = timestamp::now_seconds();
        let cap = 100000000000;
        create_launch<USDT, ETH>(
            acc, 
            signer::address_of(acc), 
            now + 100, //start
            now + 200, //end
            now + 300, // distribute
            amount, // total offer
            400000000, // sale price
            cap, //max
            cap + 1 //max per user
        );
        let new_cap = (((amount as u128) * PRICE_PRECISION / 400000000) as u64);
        dev::create_account_for_test(bob);
        dev::register_coins(bob);
        coin::deposit<USDT>(signer::address_of(bob), dev::mint_for_test<USDT>(acc, new_cap));
        
        dev::create_account_for_test(alice);
        dev::register_coins(alice);
        coin::deposit<USDT>(signer::address_of(alice), dev::mint_for_test<USDT>(acc, new_cap));
        
        
        // 1. alice deposit
        timestamp::fast_forward_seconds(100);
        let pool_0 = borrow_global<Pool<ETH>>(signer::address_of(acc));
        let max_raised = pool_0.max_raised;
        deposit<USDT, ETH>(alice, max_raised);
        
        let pool = borrow_global<Pool<ETH>>(signer::address_of(acc));
        
        assert!(pool.max_raised == pool.total_subscribed_amount, 0);
        
        // 2. bob deposit again. but should fail
        timestamp::fast_forward_seconds(10);
        deposit<USDT, ETH>(bob, 1);
        
    }

    #[test(acc=@HoustonLaunchPad, alice=@0xA11CE)]
    #[expected_failure(abort_code = 2, location = Self)]
    fun test_stake_fail_no_pool(acc: &signer, alice: &signer) acquires Pool, UserInfo, PaymentStore {
        // 0. setup and launch
        test_launch_overflow(acc);
        dev::create_account_for_test(alice);
        deposit<ETH, USDT>(alice, 1); // wrong pool
    }

    #[test(acc=@HoustonLaunchPad, alice=@0xA11CE)]
    #[expected_failure(abort_code = 3, location = Self)]
    fun test_stake_fail_time(acc: &signer, alice: &signer) acquires Pool, UserInfo, PaymentStore {
        // 0. setup and launch
        test_launch_overflow(acc);
        
        // 1. alice deposit on before start time
        deposit<USDT, ETH>(alice, 1);
    }

    #[test(acc=@HoustonLaunchPad, alice=@0xA11CE)]
    #[expected_failure(abort_code = 3, location = Self)]
    fun test_stake_fail_time_2(acc: &signer, alice: &signer) acquires Pool, UserInfo, PaymentStore {
        // 0. setup and launch
        test_launch_overflow(acc);
        // 1. alice deposit after end time
        timestamp::fast_forward_seconds(10000);
        deposit<USDT, ETH>(alice, 1);
    }

    #[test(acc=@HoustonLaunchPad, alice=@0xA11CE)]
    #[expected_failure(abort_code = 16, location = Self)]
    fun test_stake_fail_payment_token(acc: &signer, alice: &signer) acquires Pool, UserInfo, PaymentStore {
        // 0. setup and launch
        test_launch_overflow(acc);
        // 1. alice deposit with wrong payment token
        timestamp::fast_forward_seconds(100);
        deposit<DAI, ETH>(alice, 1);
    }

    #[test(acc=@HoustonLaunchPad, alice=@0xA11CE, bob=@0xB0B)]
    fun test_claim_no_overflow_no_vesting(acc: &signer, alice: &signer, bob: &signer) acquires Pool, PaymentStore, UserInfo {
        test_stake_no_overflow(acc, alice, bob);
        let addr = signer::address_of(acc);
        let alice_addr = signer::address_of(alice);
        let _bob_addr = signer::address_of(bob);

        let pool = borrow_global<Pool<ETH>>(addr);
        let dis_time = pool.distribute_start_time;
        let alice_info = borrow_global<UserInfo<ETH>>(alice_addr);
        // let bob_info = borrow_global<UserInfo<ETH>>(bob_addr);
        timestamp::fast_forward_seconds(dis_time - timestamp::now_seconds());
        let claimable = (((alice_info.subscribed_amount as u128) * pool.sale_price / PRICE_PRECISION) as u64);
        let alice_claimable = get_claimable_amount<ETH>(pool, alice_info.entitled, alice_info.claimed, timestamp::now_seconds());
        assert!(claimable == alice_claimable, 0);
        
        let tokens_bef = coin::value<ETH>(&pool.offer_coins);
        claim<USDT, ETH>(alice);
        let bal = coin::balance<ETH>(alice_addr);
        let alice_info = borrow_global<UserInfo<ETH>>(alice_addr);
        let pool = borrow_global<Pool<ETH>>(addr);
        let tokens_aft = coin::value<ETH>(&pool.offer_coins);
        assert!(alice_info.claimed == alice_info.entitled, 0);
        assert!(bal == claimable, 0);
        assert!(tokens_bef - tokens_aft == claimable, 0);
        assert!((pool.total_offer_amount as u128) == ((pool.max_raised as u128) * pool.sale_price / PRICE_PRECISION), 0); // no change on this number
    }

    #[test(acc=@HoustonLaunchPad, alice=@0xA11CE, bob=@0xB0B)]
    fun test_claim_no_overflow_vesting(acc: &signer, alice: &signer, bob: &signer) acquires Pool, PaymentStore, UserInfo {
        // 0. setup
        let addr = signer::address_of(acc);
        dev::setup();
        dev::create_account_for_test(acc);
        dev::initialize_coins(acc);
        dev::register_coins(acc);
        let amount = 1000000000000; //10000E8
        coin::deposit<ETH>(addr, dev::mint_for_test<ETH>(acc, amount));
        dev::create_account_for_test(alice);
        dev::register_coins(alice);
        let max = ((1000000000 * (amount as u128) / PRICE_PRECISION) as u64);
        let alice_addr = signer::address_of(alice);
        coin::deposit<USDT>(alice_addr, dev::mint_for_test<USDT>(acc, (max as u64)));
        
        dev::create_account_for_test(bob);
        dev::register_coins(bob);
        let bob_addr = signer::address_of(bob);
        coin::deposit<USDT>(bob_addr, dev::mint_for_test<USDT>(acc, (max as u64)));
        
        let now = timestamp::now_seconds();

        
        // 1. launch
        create_launch<USDT, ETH>(
            acc, 
            signer::address_of(acc), 
            now + 100, //start
            now + 200, //end
            now + 300, // distribute
            amount, // total offer
            1000000000000000, // sale price
            max, //max
            max / 10 //max per user
        );

        let one_month = 86400 * 30;
        // 2. add vesting period
        add_vesting<ETH>(acc, TGE_PERCENT_DENOM / 10, one_month, one_month * 3);
        let pool = borrow_global<Pool<ETH>>(addr);
        let max = pool.max_raised;
        let price = pool.sale_price;

        
        // 1. alice deposit
        timestamp::fast_forward_seconds(100);
        deposit<USDT, ETH>(alice, max / 10);
        
        // 2. bob deposit
        deposit<USDT, ETH>(bob, max / 10);
        
        // 3. verify claimable
        let pool = borrow_global<Pool<ETH>>(addr);
        let dis_time = pool.distribute_start_time;
        let alice_info = borrow_global<UserInfo<ETH>>(alice_addr);
        // let bob_info = borrow_global<UserInfo<ETH>>(bob_addr);
        timestamp::fast_forward_seconds(dis_time - timestamp::now_seconds());
        let claimable = (((alice_info.subscribed_amount as u128) * price / PRICE_PRECISION) as u64) / 10;
        let alice_claimable = get_claimable_amount<ETH>(pool, alice_info.entitled, alice_info.claimed, timestamp::now_seconds());
        assert!(claimable == alice_claimable, 0);
        // 4. claim
        claim<USDT, ETH>(alice);
        let bal = coin::balance<ETH>(alice_addr);
        let alice_info = borrow_global<UserInfo<ETH>>(alice_addr);
        assert!(alice_info.claimed < alice_info.entitled, 0);
        assert!(bal == claimable, 0);
        // 5. claim again after 1 month
        timestamp::fast_forward_seconds(one_month);
        let pool = borrow_global<Pool<ETH>>(addr);
        let claimable = (((alice_info.subscribed_amount as u128) * price / PRICE_PRECISION) as u64) * 9 / 10 / 3;
        let alice_claimable_2 = get_claimable_amount<ETH>(pool, alice_info.entitled, alice_info.claimed, timestamp::now_seconds());
        
        claim<USDT, ETH>(alice);
        let bal = coin::balance<ETH>(alice_addr);
        let alice_info = borrow_global<UserInfo<ETH>>(alice_addr);
        assert!(alice_info.claimed < alice_info.entitled, 0);
        assert!(alice_claimable_2 == claimable, 0);
        assert!(bal == alice_claimable + alice_claimable_2, 0);

        // 6. claim again after 2 months and 3 days
        timestamp::fast_forward_seconds(one_month + 86400 * 3);
        let pool = borrow_global<Pool<ETH>>(addr);
        let claimable = (((alice_info.subscribed_amount as u128) * price / PRICE_PRECISION) as u64) * 9 / 10 / 3;
        let alice_claimable_3 = get_claimable_amount<ETH>(pool, alice_info.entitled, alice_info.claimed, timestamp::now_seconds());
        
        claim<USDT, ETH>(alice);
        let bal = coin::balance<ETH>(alice_addr);
        let alice_info = borrow_global<UserInfo<ETH>>(alice_addr);
        assert!(alice_info.claimed < alice_info.entitled, 0);
        assert!(alice_claimable_3 == claimable, 0);
        assert!(bal == alice_claimable + alice_claimable_2 + alice_claimable_3, 0);

        timestamp::fast_forward_seconds(one_month * 3);
        claim<USDT, ETH>(alice);
        let alice_info = borrow_global<UserInfo<ETH>>(alice_addr);
        assert!(alice_info.claimed == alice_info.entitled, 0);
        

        

    }

    #[test(acc=@HoustonLaunchPad, alice=@0xA11CE, bob=@0xB0B)]
    fun test_claim_no_overflow_vesting_fail_too_early_claim(acc: &signer, alice: &signer, bob: &signer) acquires Pool, PaymentStore, UserInfo {
        // 0. setup
        let addr = signer::address_of(acc);
        dev::setup();
        dev::create_account_for_test(acc);
        dev::initialize_coins(acc);
        dev::register_coins(acc);
        let amount = 1000000000000; //10000E8
        coin::deposit<ETH>(addr, dev::mint_for_test<ETH>(acc, amount));
        dev::create_account_for_test(alice);
        dev::register_coins(alice);
        let max = ((1000000000 * (amount as u128) / PRICE_PRECISION) as u64);
        let alice_addr = signer::address_of(alice);
        coin::deposit<USDT>(alice_addr, dev::mint_for_test<USDT>(acc, (max as u64)));
        
        dev::create_account_for_test(bob);
        dev::register_coins(bob);
        let bob_addr = signer::address_of(bob);
        coin::deposit<USDT>(bob_addr, dev::mint_for_test<USDT>(acc, (max as u64)));
        
        let now = timestamp::now_seconds();

        
        // 1. launch
        create_launch<USDT, ETH>(
            acc, 
            signer::address_of(acc), 
            now + 100, //start
            now + 200, //end
            now + 300, // distribute
            amount, // total offer
            1000000000000000, // sale price
            max, //max
            max / 10 //max per user
        );

        let one_month = 86400 * 30;
        // 2. add vesting period
        add_vesting<ETH>(acc, TGE_PERCENT_DENOM / 10, one_month, one_month * 3);
        let pool = borrow_global<Pool<ETH>>(addr);
        let max = pool.max_raised;
        let price = pool.sale_price;

        
        // 1. alice deposit
        timestamp::fast_forward_seconds(100);
        deposit<USDT, ETH>(alice, max / 10);
        
        // 2. bob deposit
        deposit<USDT, ETH>(bob, max / 10);
        
        // 3. verify claimable
        let pool = borrow_global<Pool<ETH>>(addr);
        let dis_time = pool.distribute_start_time;
        let alice_info = borrow_global<UserInfo<ETH>>(alice_addr);
        // let bob_info = borrow_global<UserInfo<ETH>>(bob_addr);
        timestamp::fast_forward_seconds(dis_time - timestamp::now_seconds());
        let claimable = (((alice_info.subscribed_amount as u128) * price / PRICE_PRECISION) as u64) / 10;
        let alice_claimable = get_claimable_amount<ETH>(pool, alice_info.entitled, alice_info.claimed, timestamp::now_seconds());
        assert!(claimable == alice_claimable, 0);
        // 4. claim
        claim<USDT, ETH>(alice);
        let bal = coin::balance<ETH>(alice_addr);
        let alice_info = borrow_global<UserInfo<ETH>>(alice_addr);
        let claimed = alice_info.claimed;
        assert!(claimed > 0, 0);
        assert!(bal > 0, 0);
        // 5. claim again after 1 month - 1 days
        timestamp::fast_forward_seconds(one_month - 86400);
        claim<USDT, ETH>(alice);
        let bal_2 = coin::balance<ETH>(alice_addr);
        let alice_info_2 = borrow_global<UserInfo<ETH>>(alice_addr);
        assert!(bal_2 == bal, 0);
        assert!(alice_info_2.claimed == claimed, 0);
    }

    #[test(acc=@HoustonLaunchPad, alice=@0xA11CE, bob=@0xB0B)]
    fun test_claim_overflow_no_vesting_with_refund(acc: &signer, alice: &signer, bob: &signer) acquires Pool, PaymentStore, UserInfo {
        test_stake_overflow(acc, alice, bob);
        let addr = signer::address_of(acc);
        let alice_addr = signer::address_of(alice);
        let _bob_addr = signer::address_of(bob);

        let pool = borrow_global<Pool<ETH>>(addr);
        let total_subcribed = pool.total_subscribed_amount;
        let total_offer = pool.total_offer_amount;

        let dis_time = pool.distribute_start_time;
        let alice_info = borrow_global<UserInfo<ETH>>(alice_addr);
        timestamp::fast_forward_seconds(dis_time - timestamp::now_seconds());
        
        let claimable = ((alice_info.subscribed_amount as u128) * (total_offer as u128) / (total_subcribed as u128) as u64);
        let non_overflow_claim = (alice_info.subscribed_amount as u128) * pool.sale_price / PRICE_PRECISION;
        claimable = if((non_overflow_claim as u64)< claimable) (non_overflow_claim as u64) else claimable;
        let alice_claimable = get_claimable_amount<ETH>(pool, claimable, alice_info.claimed, timestamp::now_seconds());
        assert!(claimable == alice_claimable, 0);
        
        let tokens_bef = coin::value<ETH>(&pool.offer_coins);
        let alice_usdt_bef = coin::balance<USDT>(alice_addr);
        claim<USDT, ETH>(alice);
        let bal = coin::balance<ETH>(alice_addr);
        let alice_usdt_aft = coin::balance<USDT>(alice_addr);
        let alice_info = borrow_global<UserInfo<ETH>>(alice_addr);
        let pool = borrow_global<Pool<ETH>>(addr);
        let tokens_aft = coin::value<ETH>(&pool.offer_coins);
        assert!(alice_info.claimed == alice_info.entitled, 0);
        assert!(bal == claimable, 0);
        assert!(tokens_bef - tokens_aft == claimable, 0);
        if(claimable < (non_overflow_claim as u64)) {
            assert!(alice_usdt_aft - alice_usdt_bef > 0, 0);
        } else {
            assert!(alice_usdt_aft == alice_usdt_bef, 0);
        };
        
    }

    #[test(acc=@HoustonLaunchPad, alice=@0xA11CE, _bob=@0xB0B)]
    fun test_claim_overflow_no_vesting_no_refund(acc: &signer, alice: &signer, _bob: &signer) acquires Pool, PaymentStore, UserInfo {
        let addr = signer::address_of(acc);
        let alice_addr = signer::address_of(alice);
        // let _bob_addr = signer::address_of(bob);
        
        test_launch_overflow(acc);
        let pool = borrow_global<Pool<ETH>>(addr);
        let total_offer = pool.total_offer_amount;
        let price = pool.sale_price;
        let dis_time = pool.distribute_start_time;
        let max = (((total_offer as u128) * PRICE_PRECISION / price) as u64);
        max = if(pool.max_raised_per_user < max) pool.max_raised_per_user else max;
        dev::create_account_for_test(alice);
        dev::register_coins(alice);
        coin::deposit<USDT>(alice_addr, dev::mint_for_test<USDT>(acc, max));
        
        // 1. alice deposit
        timestamp::fast_forward_seconds(100);
        deposit<USDT, ETH>(alice, max / 2);
        
        let pool = borrow_global<Pool<ETH>>(addr);
        let alice_info = borrow_global<UserInfo<ETH>>(alice_addr);
        timestamp::fast_forward_seconds(dis_time - timestamp::now_seconds());
        
        let non_overflow_claim = (((alice_info.subscribed_amount as u128) * price / PRICE_PRECISION) as u64);
        
        let tokens_bef = coin::value<ETH>(&pool.offer_coins);
        let alice_usdt_bef = coin::balance<USDT>(alice_addr);
        claim<USDT, ETH>(alice);
        let bal = coin::balance<ETH>(alice_addr);
        let alice_usdt_aft = coin::balance<USDT>(alice_addr);
        let alice_info = borrow_global<UserInfo<ETH>>(alice_addr);
        let pool = borrow_global<Pool<ETH>>(addr);
        let tokens_aft = coin::value<ETH>(&pool.offer_coins);
        assert!(alice_info.claimed == alice_info.entitled, 0);
        assert!(bal == non_overflow_claim, 0);
        assert!(tokens_bef - tokens_aft == non_overflow_claim, 0);
        assert!(alice_usdt_aft == alice_usdt_bef, 0);
        
    }

    #[test(acc=@HoustonLaunchPad, alice=@0xA11CE, bob=@0xB0B)]
    fun test_claim_overflow_vesting_with_refund(acc: &signer, alice: &signer, bob: &signer) acquires Pool, PaymentStore, UserInfo {
        let addr = signer::address_of(acc);
        test_launch_overflow(acc);
        let one_month = 86400 * 30;
        // 2. add vesting period
        add_vesting<ETH>(acc, TGE_PERCENT_DENOM / 10, one_month, one_month * 3);
        let pool = borrow_global<Pool<ETH>>(addr);
        let price = pool.sale_price;
        let max = (((pool.total_offer_amount as u128) * PRICE_PRECISION / price) as u64) ;
        // 3. set up alice and bob
        dev::create_account_for_test(alice);
        dev::register_coins(alice);
        let alice_addr = signer::address_of(alice);
        coin::deposit<USDT>(alice_addr, dev::mint_for_test<USDT>(acc, max));
        
        dev::create_account_for_test(bob);
        dev::register_coins(bob);
        let bob_addr = signer::address_of(bob);
        coin::deposit<USDT>(bob_addr, dev::mint_for_test<USDT>(acc, max));
        
        

        
        // 1. alice deposit
        timestamp::fast_forward_seconds(100);
        let cap = SubscribeCapability{};
        deposit_with_cap<USDT, ETH>(alice, max, &cap);
        
        // 2. bob deposit
        deposit_with_cap<USDT, ETH>(bob, max / 10, &cap);
        let SubscribeCapability{} = cap;
        

        let pool = borrow_global<Pool<ETH>>(addr);
        let total_subcribed = pool.total_subscribed_amount;
        let total_offer = pool.total_offer_amount;

        let dis_time = pool.distribute_start_time;
        timestamp::fast_forward_seconds(dis_time - timestamp::now_seconds());
        let alice_info = borrow_global<UserInfo<ETH>>(alice_addr);
        
        let claimable = ((alice_info.subscribed_amount as u128) * (total_offer as u128) / (total_subcribed as u128) as u64);
        let non_overflow_claim = (alice_info.subscribed_amount as u128) * pool.sale_price / PRICE_PRECISION;
        claimable = if((non_overflow_claim as u64)< claimable) (non_overflow_claim as u64) else claimable;
        let alice_claimable = get_claimable_amount<ETH>(pool, claimable, alice_info.claimed, timestamp::now_seconds());
        assert!(claimable == alice_claimable * 10, 0);
        
        let tokens_bef = coin::value<ETH>(&pool.offer_coins);
        let alice_usdt_bef = coin::balance<USDT>(alice_addr);
        // 3. alice claim on distribute time
        claim<USDT, ETH>(alice);
        let bal = coin::balance<ETH>(alice_addr);
        let alice_usdt_aft = coin::balance<USDT>(alice_addr);
        let alice_info = borrow_global<UserInfo<ETH>>(alice_addr);
        let pool = borrow_global<Pool<ETH>>(addr);
        let tokens_aft = coin::value<ETH>(&pool.offer_coins);
        assert!(alice_info.claimed < alice_info.entitled, 0);
        assert!(bal == alice_claimable, 0);
        assert!(tokens_bef - tokens_aft == alice_claimable, 0);
        assert!(alice_usdt_aft - alice_usdt_bef > 0, 0);

        // 4. claim again after 1 month
        timestamp::fast_forward_seconds(one_month);
        let pool = borrow_global<Pool<ETH>>(addr);
        let claimable = (((alice_info.subscribed_amount as u128) * (total_offer as u128) / (total_subcribed as u128)) as u64) * 9 / 10 / 3;
        let alice_claimable_2 = get_claimable_amount<ETH>(pool, alice_info.entitled, alice_info.claimed, timestamp::now_seconds());
        let alice_usdt_bef = coin::balance<USDT>(alice_addr);
        
        claim<USDT, ETH>(alice);
        let bal = coin::balance<ETH>(alice_addr);
        let alice_info = borrow_global<UserInfo<ETH>>(alice_addr);
        let alice_usdt_aft = coin::balance<USDT>(alice_addr);
        assert!(alice_info.claimed < alice_info.entitled, 0);
        assert!(alice_claimable_2 == claimable, 0);
        assert!(bal == alice_claimable + alice_claimable_2, 0);
        assert!(alice_usdt_aft - alice_usdt_bef == 0, 0);

        // 6. claim again after 2 months and 3 days
        timestamp::fast_forward_seconds(one_month + 86400 * 3);
        let pool = borrow_global<Pool<ETH>>(addr);
        let claimable = (((alice_info.subscribed_amount as u128) * (total_offer as u128) / (total_subcribed as u128)) as u64) * 9 / 10 / 3;
        let alice_claimable_3 = get_claimable_amount<ETH>(pool, alice_info.entitled, alice_info.claimed, timestamp::now_seconds());
        
        claim<USDT, ETH>(alice);
        let bal = coin::balance<ETH>(alice_addr);
        let alice_info = borrow_global<UserInfo<ETH>>(alice_addr);
        assert!(alice_info.claimed < alice_info.entitled, 0);
        assert!(alice_claimable_3 == claimable, 0);
        assert!(bal == alice_claimable + alice_claimable_2 + alice_claimable_3, 0);

        // claim all after 3 months
        timestamp::fast_forward_seconds(one_month * 3);
        claim<USDT, ETH>(alice);
        let alice_info = borrow_global<UserInfo<ETH>>(alice_addr);
        assert!(alice_info.claimed == alice_info.entitled, 0);
        
        
    }

    #[test(acc=@HoustonLaunchPad, alice=@0xA11CE, bob=@0xB0B)]
    fun test_claim_overflow_vesting_with_refund_two_tokens(acc: &signer, alice: &signer, bob: &signer) acquires Pool, PaymentStore, UserInfo {
        let addr = signer::address_of(acc);
        test_launch_overflow(acc);
        let one_month = 86400 * 30;
        // 2. add vesting period
        add_vesting<ETH>(acc, TGE_PERCENT_DENOM / 10, one_month, one_month * 3);
        // 2.1 add payment token
        add_payment_tokens<ABC, ETH>(acc);
        
        let pool = borrow_global<Pool<ETH>>(addr);
        let price = pool.sale_price;
        let max = (((pool.total_offer_amount as u128) * PRICE_PRECISION / price) as u64) ;
        // 3. set up alice and bob
        dev::create_account_for_test(alice);
        dev::register_coins(alice);
        let alice_addr = signer::address_of(alice);
        coin::deposit<USDT>(alice_addr, dev::mint_for_test<USDT>(acc, max));
        coin::deposit<ABC>(alice_addr, dev::mint_for_test<ABC>(acc, max));
        
        dev::create_account_for_test(bob);
        dev::register_coins(bob);
        let bob_addr = signer::address_of(bob);
        coin::deposit<USDT>(bob_addr, dev::mint_for_test<USDT>(acc, max));
        
        

        
        // 1. alice deposit
        timestamp::fast_forward_seconds(100);
        let cap = SubscribeCapability{};
        deposit_with_cap<USDT, ETH>(alice, max, &cap);
        deposit_with_cap<ABC, ETH>(alice, max, &cap);
        
        // 2. bob deposit
        deposit_with_cap<USDT, ETH>(bob, max / 10, &cap);
        let SubscribeCapability{} = cap;
        

        let pool = borrow_global<Pool<ETH>>(addr);
        let total_subcribed = pool.total_subscribed_amount;
        let total_offer = pool.total_offer_amount;

        let dis_time = pool.distribute_start_time;
        timestamp::fast_forward_seconds(dis_time - timestamp::now_seconds());
        let alice_info = borrow_global<UserInfo<ETH>>(alice_addr);
        
        let claimable = ((alice_info.subscribed_amount as u128) * (total_offer as u128) / (total_subcribed as u128) as u64);
        let non_overflow_claim = (alice_info.subscribed_amount as u128) * pool.sale_price / PRICE_PRECISION;
        claimable = if((non_overflow_claim as u64)< claimable) (non_overflow_claim as u64) else claimable;
        let alice_claimable = get_claimable_amount<ETH>(pool, claimable, alice_info.claimed, timestamp::now_seconds());
        assert!(claimable == alice_claimable * 10, 0);
        
        let tokens_bef = coin::value<ETH>(&pool.offer_coins);
        let alice_usdt_bef = coin::balance<USDT>(alice_addr);
        let alice_abc_bef = coin::balance<ABC>(alice_addr);
        // 3. alice claim on distribute time
        claim<USDT, ETH>(alice);
        claim<ABC, ETH>(alice);
        let bal = coin::balance<ETH>(alice_addr);
        let alice_usdt_aft = coin::balance<USDT>(alice_addr);
        let alice_info = borrow_global<UserInfo<ETH>>(alice_addr);
        let pool = borrow_global<Pool<ETH>>(addr);
        let tokens_aft = coin::value<ETH>(&pool.offer_coins);
        assert!(alice_info.claimed < alice_info.entitled, 0);
        assert!(bal == alice_claimable, 0);
        assert!(tokens_bef - tokens_aft == alice_claimable, 0);
        assert!(alice_usdt_aft - alice_usdt_bef > 0, 0);
        
        let alice_abc_aft = coin::balance<ABC>(alice_addr);
        assert!(alice_abc_aft - alice_abc_bef > 0, 0);


        // 4. claim again after 1 month
        timestamp::fast_forward_seconds(one_month);
        let pool = borrow_global<Pool<ETH>>(addr);
        let claimable = (((alice_info.subscribed_amount as u128) * (total_offer as u128) / (total_subcribed as u128)) as u64) * 9 / 10 / 3;
        let alice_claimable_2 = get_claimable_amount<ETH>(pool, alice_info.entitled, alice_info.claimed, timestamp::now_seconds());
        let alice_usdt_bef = coin::balance<USDT>(alice_addr);
        
        claim<USDT, ETH>(alice);
        let bal = coin::balance<ETH>(alice_addr);
        let alice_info = borrow_global<UserInfo<ETH>>(alice_addr);
        let alice_usdt_aft = coin::balance<USDT>(alice_addr);
        assert!(alice_info.claimed < alice_info.entitled, 0);
        assert!(alice_claimable_2 == claimable, 0);
        assert!(bal == alice_claimable + alice_claimable_2, 0);
        assert!(alice_usdt_aft - alice_usdt_bef == 0, 0);

        // 6. claim again after 2 months and 3 days
        timestamp::fast_forward_seconds(one_month + 86400 * 3);
        let pool = borrow_global<Pool<ETH>>(addr);
        let claimable = (((alice_info.subscribed_amount as u128) * (total_offer as u128) / (total_subcribed as u128)) as u64) * 9 / 10 / 3;
        let alice_claimable_3 = get_claimable_amount<ETH>(pool, alice_info.entitled, alice_info.claimed, timestamp::now_seconds());
        
        claim<USDT, ETH>(alice);
        let bal = coin::balance<ETH>(alice_addr);
        let alice_info = borrow_global<UserInfo<ETH>>(alice_addr);
        assert!(alice_info.claimed < alice_info.entitled, 0);
        assert!(alice_claimable_3 == claimable, 0);
        assert!(bal == alice_claimable + alice_claimable_2 + alice_claimable_3, 0);

        // claim all after 3 months
        timestamp::fast_forward_seconds(one_month * 3);
        claim<USDT, ETH>(alice);
        let alice_info = borrow_global<UserInfo<ETH>>(alice_addr);
        assert!(alice_info.claimed == alice_info.entitled, 0);
        
        
    }

    #[test(acc=@HoustonLaunchPad, alice=@0xA11CE, bob=@0xB0B)]
    #[expected_failure(abort_code = 10, location = Self)]
    fun test_claim_fail_no_deposit(acc: &signer, alice: &signer, bob: &signer) acquires Pool, PaymentStore, UserInfo {
        // 0. setup
        let addr = signer::address_of(acc);
        dev::setup();
        dev::create_account_for_test(acc);
        dev::initialize_coins(acc);
        dev::register_coins(acc);
        let amount = 1000000000000; //10000E8
        coin::deposit<ETH>(addr, dev::mint_for_test<ETH>(acc, amount));
        dev::create_account_for_test(alice);
        dev::register_coins(alice);
        let max = ((1000000000 * (amount as u128) / PRICE_PRECISION) as u64);
        let alice_addr = signer::address_of(alice);
        coin::deposit<USDT>(alice_addr, dev::mint_for_test<USDT>(acc, (max as u64)));
        
        dev::create_account_for_test(bob);
        dev::register_coins(bob);
        let bob_addr = signer::address_of(bob);
        coin::deposit<USDT>(bob_addr, dev::mint_for_test<USDT>(acc, (max as u64)));
        
        let now = timestamp::now_seconds();

        
        // 1. launch
        create_launch<USDT, ETH>(
            acc, 
            signer::address_of(acc), 
            now + 100, //start
            now + 200, //end
            now + 300, // distribute
            amount, // total offer
            1000000000000000, // sale price
            max, //max
            max / 10 //max per user
        );

        let one_month = 86400 * 30;
        // 2. add vesting period
        add_vesting<ETH>(acc, TGE_PERCENT_DENOM / 10, one_month, one_month * 3);
        let pool = borrow_global<Pool<ETH>>(addr);
        let max = pool.max_raised;
        let dis_time = pool.distribute_start_time;

        
        // 1. alice deposit
        timestamp::fast_forward_seconds(100);
        deposit<USDT, ETH>(alice, max / 10);
        
        timestamp::fast_forward_seconds(dis_time - timestamp::now_seconds());
        // 2. bob try to claim
        claim<USDT, ETH>(bob);
        
    }

    #[test(acc=@HoustonLaunchPad)]
    #[expected_failure(abort_code = 2, location = Self)]
    fun test_claim_fail_no_pool(acc: &signer) acquires Pool, UserInfo, PaymentStore {
        // 0. setup
        dev::setup();
        dev::create_account_for_test(acc);
        dev::initialize_coins(acc);
        dev::register_coins(acc);
        
        // 1. acc try to claim, no pool
        claim<USDT, ETH>(acc);
        
    }

    #[test(acc=@HoustonLaunchPad, alice=@0xA11CE, bob=@0xB0B)]
    fun test_withdraw_payment_no_overflow(acc: &signer, alice: &signer, bob: &signer) acquires Pool, UserInfo, PaymentStore {
        test_stake_no_overflow(acc, alice, bob);
        let acc_addr = signer::address_of(acc);
        
        let pool = borrow_global<Pool<ETH>>(acc_addr);
        timestamp::fast_forward_seconds(pool.end_time - timestamp::now_seconds() + 1);
        let init_bal = coin::balance<USDT>(acc_addr);
        let payment_store = borrow_global<PaymentStore<USDT, ETH>>(acc_addr);
        let left = coin::value<USDT>(&payment_store.payment_coins);
        withdraw_payment<USDT, ETH>(acc);
        let aft_bal = coin::balance<USDT>(acc_addr);
        assert!(aft_bal - init_bal == left, 0);
        let payment_store = borrow_global<PaymentStore<USDT, ETH>>(acc_addr);
        assert!(coin::value<USDT>(&payment_store.payment_coins) == 0, 0);
    }

    #[test(acc=@HoustonLaunchPad, alice=@0xA11CE, bob=@0xB0B)]
    fun test_withdraw_payment_overflow(acc: &signer, alice: &signer, bob: &signer) acquires Pool, UserInfo, PaymentStore {
        test_stake_overflow(acc, alice, bob);
        let acc_addr = signer::address_of(acc);
        let pool = borrow_global<Pool<ETH>>(acc_addr);
        timestamp::fast_forward_seconds(pool.end_time - timestamp::now_seconds() + 1);
        let init_bal = coin::balance<USDT>(acc_addr);
        let payment_store = borrow_global<PaymentStore<USDT, ETH>>(acc_addr);
        let left = coin::value<USDT>(&payment_store.payment_coins);
        withdraw_payment<USDT, ETH>(acc);
        let aft_bal = coin::balance<USDT>(acc_addr);
        assert!(aft_bal - init_bal < left, 0);
        let payment_store = borrow_global<PaymentStore<USDT, ETH>>(acc_addr);
        let pool = borrow_global<Pool<ETH>>(acc_addr);
        let refund = pool.total_subscribed_amount - (((pool.total_offer_amount as u128) * PRICE_PRECISION / pool.sale_price) as u64); 
        assert!(coin::value<USDT>(&payment_store.payment_coins) == refund, 0);
        
    }
    #[test(acc=@HoustonLaunchPad, alice=@0xA11CE, bob=@0xB0B)]
    fun test_withdraw_payment_overflow_two_tokens(acc: &signer, alice: &signer, bob: &signer) acquires Pool, UserInfo, PaymentStore {
        test_stake_overflow_2_tokens(acc, alice, bob);
        let acc_addr = signer::address_of(acc);
        let pool = borrow_global<Pool<ETH>>(acc_addr);
        timestamp::fast_forward_seconds(pool.end_time - timestamp::now_seconds() + 1);
        let init_bal = coin::balance<USDT>(acc_addr);
        let payment_store = borrow_global<PaymentStore<USDT, ETH>>(acc_addr);
        let left = coin::value<USDT>(&payment_store.payment_coins);
        withdraw_payment<USDT, ETH>(acc);
        let aft_bal = coin::balance<USDT>(acc_addr);
        assert!(aft_bal - init_bal < left, 0);
        let payment_store = borrow_global<PaymentStore<USDT, ETH>>(acc_addr);
        let pool = borrow_global<Pool<ETH>>(acc_addr);
        let refund_total = (pool.total_subscribed_amount - (((pool.total_offer_amount as u128) * PRICE_PRECISION / pool.sale_price) as u64));
        let withdrawal = refund_total - refund_total / 3; 
        assert!(coin::value<USDT>(&payment_store.payment_coins) == withdrawal, 0);
        
        let init_bal = coin::balance<ABC>(acc_addr);
        let payment_store = borrow_global<PaymentStore<ABC, ETH>>(acc_addr);
        let left = coin::value<ABC>(&payment_store.payment_coins);
        withdraw_payment<ABC, ETH>(acc);
        let aft_bal = coin::balance<ABC>(acc_addr);
        assert!(aft_bal - init_bal < left, 0);
        let payment_store = borrow_global<PaymentStore<ABC, ETH>>(acc_addr);
        let withdrawal = refund_total - 2 * refund_total / 3; 
        assert!(coin::value<ABC>(&payment_store.payment_coins) == withdrawal, 0);
    }

    #[test(acc=@HoustonLaunchPad, alice=@0xA11CE, bob=@0xB0B)]
    fun test_withdraw_payment_overflow_no_refund(acc: &signer, alice: &signer, bob: &signer) acquires Pool, UserInfo, PaymentStore {
        test_claim_overflow_no_vesting_no_refund(acc, alice, bob);
        let acc_addr = signer::address_of(acc);
        let init_bal = coin::balance<USDT>(acc_addr);
        let payment_store = borrow_global<PaymentStore<USDT, ETH>>(acc_addr);
        let left = coin::value<USDT>(&payment_store.payment_coins);
        withdraw_payment<USDT, ETH>(acc);
        let aft_bal = coin::balance<USDT>(acc_addr);
        assert!(aft_bal - init_bal == left, 0);
        let payment_store = borrow_global<PaymentStore<USDT, ETH>>(acc_addr);
        assert!(coin::value<USDT>(&payment_store.payment_coins) == 0, 0);
        
    }

    
    #[test(acc=@HoustonLaunchPad, alice=@0xA11CE, bob=@0xB0B)]
    #[expected_failure(abort_code = 11, location = Self)]
    fun test_withdraw_payment_fail_time(acc: &signer, alice: &signer, bob: &signer) acquires Pool, UserInfo, PaymentStore {
        // 0. setup
        test_stake_overflow(acc, alice, bob);
        withdraw_payment<USDT, ETH>(acc);
    }

    #[test(acc=@HoustonLaunchPad, alice=@0xA11CE, bob=@0xB0B)]
    #[expected_failure(abort_code = 8, location = Self)]
    fun test_withdraw_payment_fail_treasury(acc: &signer, alice: &signer, bob: &signer) acquires Pool, PaymentStore, UserInfo {
        test_stake_overflow(acc, alice, bob);
        timestamp::fast_forward_seconds(400);
        withdraw_payment<USDT, ETH>(alice); // not treasury
    }

    #[test(acc=@HoustonLaunchPad, alice=@0xA11CE, bob=@0xB0B)]
    #[expected_failure(abort_code = 21, location = Self)]
    fun test_withdraw_payment_fail_withdraw_twice(acc: &signer, alice: &signer, bob: &signer) acquires Pool, PaymentStore, UserInfo {
        test_stake_overflow(acc, alice, bob);
        timestamp::fast_forward_seconds(400);
        withdraw_payment<USDT, ETH>(acc); 
        withdraw_payment<USDT, ETH>(acc); 
    }

    #[test(acc=@HoustonLaunchPad, alice=@0xA11CE, bob=@0xB0B)]
    fun test_with_ugly_numbers(acc: &signer, alice: &signer, bob: &signer) acquires Pool, PaymentStore, UserInfo {
        dev::setup();
        dev::create_account_for_test(acc);
        dev::initialize_coins(acc);
        dev::register_coins(acc);
        let acc_addr = signer::address_of(acc);
        let alice_addr = signer::address_of(alice);
        let bob_addr = signer::address_of(bob);
        
        let token_out_amt:u64 = 1203354354345679454;
        coin::deposit<ETH>(acc_addr, dev::mint_for_test<ETH>(acc, token_out_amt));
        let now = timestamp::now_seconds();
        let max_raised_per_user = 2456000000;
        let sale_price = 334 * PRICE_PRECISION;
        let max_raised = (((token_out_amt as u128) * PRICE_PRECISION / sale_price) as u64);
        
        create_launch<USDT, ETH>(
            acc, 
            signer::address_of(acc), 
            now + 100, //start
            now + 200, //end
            now + 300, // distribute
            token_out_amt, // total offer
            sale_price, // sale price
            1, //no overflow
            max_raised_per_user //max per user
        );

        dev::create_account_for_test(bob);
        dev::register_coins(bob);
        coin::deposit<USDT>(signer::address_of(bob), dev::mint_for_test<USDT>(acc, max_raised_per_user));
        
        dev::create_account_for_test(alice);
        dev::register_coins(alice);
        coin::deposit<USDT>(signer::address_of(alice), dev::mint_for_test<USDT>(acc, max_raised_per_user));
        
        let pool = borrow_global<Pool<ETH>>(acc_addr);
        assert!(pool.sale_price == sale_price, 0);
        assert!(pool.max_raised == max_raised, 0);
        
        // 1. alice deposit
        timestamp::fast_forward_seconds(100);
        let init_bal = coin::balance<USDT>(alice_addr);
        let alice_stake_amt = max_raised_per_user * 4/53;
        deposit<USDT, ETH>(alice, alice_stake_amt);
        let aft_bal = coin::balance<USDT>(alice_addr);
        
        let userInfo = borrow_global<UserInfo<ETH>>(alice_addr);
        assert!(userInfo.subscribed_amount == alice_stake_amt, 0);
        assert!(init_bal - aft_bal == alice_stake_amt, 0);
        
        // 2. bob deposit again. deposit above the max_raised
        timestamp::fast_forward_seconds(10);
        let init_b = coin::balance<USDT>(bob_addr);
        // let _trea_init_apt = coin::balance<USDT>(signer::address_of(acc));
        let bob_stake_amt = max_raised_per_user * 43/353;
        deposit<USDT, ETH>(bob, bob_stake_amt);
        
        let aft_b = coin::balance<USDT>(bob_addr);
        // let _trea_aft_apt = coin::balance<USDT>(signer::address_of(acc));
        
        let userInfo = borrow_global<UserInfo<ETH>>(bob_addr);
        assert!(userInfo.subscribed_amount == bob_stake_amt, 0);
        assert!(init_b - aft_b == bob_stake_amt, 0);

        // 3. acc deposit again. deposit above the max_raised
        timestamp::fast_forward_seconds(10);
        let cap = SubscribeCapability{};
        let pool = borrow_global<Pool<ETH>>(acc_addr);
        let payment_store = borrow_global<PaymentStore<USDT, ETH>>(acc_addr);
        let total_amount_in = coin::value<USDT>(&payment_store.payment_coins);
        assert!(pool.total_subscribed_amount == total_amount_in, 0);
        let acc_stake_amt = pool.max_raised - total_amount_in;
        coin::deposit<USDT>(acc_addr, dev::mint_for_test<USDT>(acc, acc_stake_amt));
        let init_a = coin::balance<USDT>(acc_addr);

        deposit_with_cap<USDT, ETH>(acc, acc_stake_amt + 10, &cap);
        let SubscribeCapability{} = cap;
        let aft_a = coin::balance<USDT>(acc_addr);
        
        let userInfo = borrow_global<UserInfo<ETH>>(acc_addr);
        assert!(userInfo.subscribed_amount == acc_stake_amt, 0);
        assert!(init_a - aft_a == acc_stake_amt, 0);
        let pool = borrow_global<Pool<ETH>>(signer::address_of(acc));
        let payment_store = borrow_global<PaymentStore<USDT, ETH>>(acc_addr);
        let total_amount_in = coin::value<USDT>(&payment_store.payment_coins);
        assert!(pool.max_raised == total_amount_in, 0);

        // 4. claim
        timestamp::fast_forward_seconds(500);
        let sale_price = pool.sale_price;
        let claimable = ((sale_price * (alice_stake_amt as u128) / PRICE_PRECISION) as u64);
        claim<USDT, ETH>(alice);
        let aft_eth = coin::balance<ETH>(alice_addr);
        assert!(aft_eth  == claimable, 0);
        let claimable = ((sale_price * (bob_stake_amt as u128) / PRICE_PRECISION) as u64);
        
        claim<USDT, ETH>(bob);
        let aft_eth = coin::balance<ETH>(bob_addr);
        assert!(aft_eth == claimable , 0);
        let init_eth = coin::balance<ETH>(acc_addr);
        let claimable = ((sale_price * (acc_stake_amt as u128) / PRICE_PRECISION) as u64);
        claim<USDT, ETH>(acc);
        let aft_eth = coin::balance<ETH>(acc_addr);
        assert!(aft_eth - init_eth == claimable, 0);

        let pool = borrow_global<Pool<ETH>>(signer::address_of(acc));
        let left = coin::value<ETH>(&pool.offer_coins);
        assert!((left as u128) * PRICE_PRECISION / sale_price == 0, 0); // some left over but not much
        assert!(left > 0, 0); // some left over but not much
        assert!(pool.total_subscribed_amount == total_amount_in, 0);
        
    }




    


        

    

}
    
}