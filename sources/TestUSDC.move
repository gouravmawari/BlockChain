module liquidity_pool::TestUSDC {
    use std::signer;
    use std::string;
    use aptos_framework::coin::{Self, MintCapability, BurnCapability};

    /// Test USDC coin type
    struct TestUSDC has key {}

    /// Capabilities to mint/burn
    struct Capabilities has key {
        mint_cap: MintCapability<TestUSDC>,
        burn_cap: BurnCapability<TestUSDC>,
    }

    /// Initialize the test token (run once)
    public entry fun initialize(account: &signer) {
        let (burn_cap, freeze_cap, mint_cap) = coin::initialize<TestUSDC>(
            account,
            string::utf8(b"Test USDC"),
            string::utf8(b"TUSDC"),
            6, // 6 decimals like real USDC
            true, // monitor_supply
        );

        // Destroy freeze capability (we don't need it)
        coin::destroy_freeze_cap(freeze_cap);

        // Store mint/burn capabilities
        move_to(account, Capabilities {
            mint_cap,
            burn_cap,
        });

        // Register the coin for this account
        coin::register<TestUSDC>(account);
    }

    /// Mint tokens to any address (for testing only!)
    public entry fun mint(
        admin: &signer,
        to: address,
        amount: u64,
    ) acquires Capabilities {
        let admin_addr = signer::address_of(admin);
        let caps = borrow_global<Capabilities>(admin_addr);
        
        // Register if needed
        if (!coin::is_account_registered<TestUSDC>(to)) {
            coin::register<TestUSDC>(admin);
        };

        let coins = coin::mint<TestUSDC>(amount, &caps.mint_cap);
        coin::deposit(to, coins);
    }

    /// Register to receive TestUSDC
    public entry fun register(account: &signer) {
        coin::register<TestUSDC>(account);
    }
}