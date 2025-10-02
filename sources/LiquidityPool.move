module liquidity_pool::LiquidityPool {
    use std::signer;
    use aptos_framework::coin::{Self, Coin};
    use aptos_std::math64;

    // Error codes
    const E_NOT_INITIALIZED: u64 = 1;
    const E_ALREADY_INITIALIZED: u64 = 2;
    const E_ZERO_AMOUNT: u64 = 3;
    const E_INSUFFICIENT_LIQUIDITY: u64 = 4;
    const E_INSUFFICIENT_OUTPUT: u64 = 5;

    // Minimum liquidity locked forever to prevent attacks
    const MINIMUM_LIQUIDITY: u64 = 1000;

    // LP Token - represents ownership in pool
    struct LPToken<phantom X, phantom Y> has key {}

    // Main liquidity pool storage
    struct Pool<phantom X, phantom Y> has key {
        coin_x: Coin<X>,
        coin_y: Coin<Y>,
        lp_supply: u64,
    }

    // Capabilities to mint/burn LP tokens
    struct Capabilities<phantom X, phantom Y> has key {
        mint_cap: coin::MintCapability<LPToken<X, Y>>,
        burn_cap: coin::BurnCapability<LPToken<X, Y>>,
    }

    // Initialize a new liquidity pool
    public entry fun initialize<X, Y>(admin: &signer) {
        let admin_addr = signer::address_of(admin);
        
        // Check pool doesn't already exist
        assert!(!exists<Pool<X, Y>>(admin_addr), E_ALREADY_INITIALIZED);

        // Create LP token
        let (burn_cap, freeze_cap, mint_cap) = coin::initialize<LPToken<X, Y>>(
            admin,
            std::string::utf8(b"LP Token"),
            std::string::utf8(b"LP"),
            8,
            true,
        );

        // Don't need freeze capability
        coin::destroy_freeze_cap(freeze_cap);

        // Store capabilities
        move_to(admin, Capabilities<X, Y> {
            mint_cap,
            burn_cap,
        });

        // Create empty pool
        move_to(admin, Pool<X, Y> {
            coin_x: coin::zero<X>(),
            coin_y: coin::zero<Y>(),
            lp_supply: 0,
        });
    }

    // Add liquidity to pool
    public entry fun add_liquidity<X, Y>(
        user: &signer,
        pool_addr: address,
        amount_x: u64,
        amount_y: u64,
    ) acquires Pool, Capabilities {
        // Validate inputs
        assert!(amount_x > 0 && amount_y > 0, E_ZERO_AMOUNT);
        assert!(exists<Pool<X, Y>>(pool_addr), E_NOT_INITIALIZED);

        // Get pool and capabilities
        let pool = borrow_global_mut<Pool<X, Y>>(pool_addr);
        let caps = borrow_global<Capabilities<X, Y>>(pool_addr);

        // Withdraw coins from user
        let coin_x = coin::withdraw<X>(user, amount_x);
        let coin_y = coin::withdraw<Y>(user, amount_y);

        // Calculate LP tokens to mint
        let liquidity = if (pool.lp_supply == 0) {
            // First liquidity provider
            let initial_liquidity = math64::sqrt(amount_x * amount_y);
            assert!(initial_liquidity > MINIMUM_LIQUIDITY, E_INSUFFICIENT_LIQUIDITY);
            
            // Lock minimum liquidity forever
            initial_liquidity - MINIMUM_LIQUIDITY
        } else {
            // Subsequent liquidity providers
            let reserve_x = coin::value(&pool.coin_x);
            let reserve_y = coin::value(&pool.coin_y);
            
            let liquidity_x = (amount_x * pool.lp_supply) / reserve_x;
            let liquidity_y = (amount_y * pool.lp_supply) / reserve_y;
            
            // Take minimum to maintain ratio
            if (liquidity_x < liquidity_y) { 
                liquidity_x 
            } else { 
                liquidity_y 
            }
        };

        assert!(liquidity > 0, E_INSUFFICIENT_LIQUIDITY);

        // Add coins to pool
        coin::merge(&mut pool.coin_x, coin_x);
        coin::merge(&mut pool.coin_y, coin_y);

        // Update LP supply
        pool.lp_supply = pool.lp_supply + liquidity;

        // Mint LP tokens
        let lp_tokens = coin::mint<LPToken<X, Y>>(liquidity, &caps.mint_cap);

        // Register user for LP token if needed
        let user_addr = signer::address_of(user);
        if (!coin::is_account_registered<LPToken<X, Y>>(user_addr)) {
            coin::register<LPToken<X, Y>>(user);
        };

        // Deposit LP tokens to user
        coin::deposit(user_addr, lp_tokens);
    }

    // Remove liquidity from pool
    public entry fun remove_liquidity<X, Y>(
        user: &signer,
        pool_addr: address,
        liquidity_amount: u64,
    ) acquires Pool, Capabilities {
        assert!(liquidity_amount > 0, E_ZERO_AMOUNT);
        assert!(exists<Pool<X, Y>>(pool_addr), E_NOT_INITIALIZED);

        let pool = borrow_global_mut<Pool<X, Y>>(pool_addr);
        let caps = borrow_global<Capabilities<X, Y>>(pool_addr);

        let reserve_x = coin::value(&pool.coin_x);
        let reserve_y = coin::value(&pool.coin_y);

        // Calculate amounts to return
        let amount_x = (liquidity_amount * reserve_x) / pool.lp_supply;
        let amount_y = (liquidity_amount * reserve_y) / pool.lp_supply;

        assert!(amount_x > 0 && amount_y > 0, E_INSUFFICIENT_OUTPUT);

        // Burn LP tokens from user
        let lp_tokens = coin::withdraw<LPToken<X, Y>>(user, liquidity_amount);
        coin::burn(lp_tokens, &caps.burn_cap);

        // Update supply
        pool.lp_supply = pool.lp_supply - liquidity_amount;

        // Extract coins from pool
        let coin_x_out = coin::extract(&mut pool.coin_x, amount_x);
        let coin_y_out = coin::extract(&mut pool.coin_y, amount_y);

        // Register user for coins if needed
        let user_addr = signer::address_of(user);
        if (!coin::is_account_registered<X>(user_addr)) {
            coin::register<X>(user);
        };
        if (!coin::is_account_registered<Y>(user_addr)) {
            coin::register<Y>(user);
        };

        // Deposit coins to user
        coin::deposit(user_addr, coin_x_out);
        coin::deposit(user_addr, coin_y_out);
    }

    // Swap X for Y
    public entry fun swap_x_for_y<X, Y>(
        user: &signer,
        pool_addr: address,
        amount_in: u64,
        min_amount_out: u64,
    ) acquires Pool {
        assert!(amount_in > 0, E_ZERO_AMOUNT);
        assert!(exists<Pool<X, Y>>(pool_addr), E_NOT_INITIALIZED);

        let pool = borrow_global_mut<Pool<X, Y>>(pool_addr);

        // Get reserves
        let reserve_x = coin::value(&pool.coin_x);
        let reserve_y = coin::value(&pool.coin_y);

        // Calculate output with 0.3% fee
        let amount_in_with_fee = amount_in * 997;
        let numerator = amount_in_with_fee * reserve_y;
        let denominator = (reserve_x * 1000) + amount_in_with_fee;
        let amount_out = numerator / denominator;

        assert!(amount_out >= min_amount_out, E_INSUFFICIENT_OUTPUT);

        // Take input from user
        let coin_in = coin::withdraw<X>(user, amount_in);
        coin::merge(&mut pool.coin_x, coin_in);

        // Give output to user
        let coin_out = coin::extract(&mut pool.coin_y, amount_out);

        let user_addr = signer::address_of(user);
        if (!coin::is_account_registered<Y>(user_addr)) {
            coin::register<Y>(user);
        };

        coin::deposit(user_addr, coin_out);
    }

    // Swap Y for X
    public entry fun swap_y_for_x<X, Y>(
        user: &signer,
        pool_addr: address,
        amount_in: u64,
        min_amount_out: u64,
    ) acquires Pool {
        assert!(amount_in > 0, E_ZERO_AMOUNT);
        assert!(exists<Pool<X, Y>>(pool_addr), E_NOT_INITIALIZED);

        let pool = borrow_global_mut<Pool<X, Y>>(pool_addr);

        // Get reserves
        let reserve_x = coin::value(&pool.coin_x);
        let reserve_y = coin::value(&pool.coin_y);

        // Calculate output with 0.3% fee
        let amount_in_with_fee = amount_in * 997;
        let numerator = amount_in_with_fee * reserve_x;
        let denominator = (reserve_y * 1000) + amount_in_with_fee;
        let amount_out = numerator / denominator;

        assert!(amount_out >= min_amount_out, E_INSUFFICIENT_OUTPUT);

        // Take input from user
        let coin_in = coin::withdraw<Y>(user, amount_in);
        coin::merge(&mut pool.coin_y, coin_in);

        // Give output to user
        let coin_out = coin::extract(&mut pool.coin_x, amount_out);

        let user_addr = signer::address_of(user);
        if (!coin::is_account_registered<X>(user_addr)) {
            coin::register<X>(user);
        };

        coin::deposit(user_addr, coin_out);
    }

    // View function: Get pool reserves
    #[view]
    public fun get_reserves<X, Y>(pool_addr: address): (u64, u64, u64) acquires Pool {
        assert!(exists<Pool<X, Y>>(pool_addr), E_NOT_INITIALIZED);
        let pool = borrow_global<Pool<X, Y>>(pool_addr);
        (
            coin::value(&pool.coin_x),
            coin::value(&pool.coin_y),
            pool.lp_supply
        )
    }

    // View function: Calculate output amount for swap
    #[view]
    public fun get_amount_out<X, Y>(
        pool_addr: address,
        amount_in: u64,
        x_to_y: bool
    ): u64 acquires Pool {
        assert!(exists<Pool<X, Y>>(pool_addr), E_NOT_INITIALIZED);
        let pool = borrow_global<Pool<X, Y>>(pool_addr);

        let reserve_x = coin::value(&pool.coin_x);
        let reserve_y = coin::value(&pool.coin_y);

        let (reserve_in, reserve_out) = if (x_to_y) {
            (reserve_x, reserve_y)
        } else {
            (reserve_y, reserve_x)
        };

        let amount_in_with_fee = amount_in * 997;
        let numerator = amount_in_with_fee * reserve_out;
        let denominator = (reserve_in * 1000) + amount_in_with_fee;
        numerator / denominator
    }
}