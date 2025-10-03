module liquidity_pool::CLOB {
    use std::signer;
    use std::vector;
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::timestamp;
    use aptos_framework::event::{Self, EventHandle};
    use aptos_framework::account;

    // ============================================
    // STEP 1: DEFINE ERROR CODES
    // These are returned when something goes wrong
    // ============================================
    const E_NOT_INITIALIZED: u64 = 1;
    const E_ALREADY_INITIALIZED: u64 = 2;
    const E_INVALID_PRICE: u64 = 3;
    const E_INVALID_SIZE: u64 = 4;
    const E_ORDER_NOT_FOUND: u64 = 5;
    const E_INSUFFICIENT_BALANCE: u64 = 6;

    // ============================================
    // STEP 2: DEFINE ORDER SIDES
    // false = BUY, true = SELL
    // ============================================
    const SIDE_BUY: bool = false;
    const SIDE_SELL: bool = true;

    // ============================================
    // STEP 3: DEFINE DATA STRUCTURES
    // ============================================

    /// Individual Order
    /// Think of this as a "sticky note" with order details
    struct Order has store, copy, drop {
        order_id: u64,          // Unique ID (like a ticket number)
        user: address,          // Who placed this order?
        side: bool,             // BUY (false) or SELL (true)
        price: u64,             // Price per coin (in smallest units)
        size: u64,              // Total amount of coins
        filled_size: u64,       // How much has been traded already
        timestamp: u64,         // When was it placed?
    }

    /// Price Level
    /// All orders at the SAME price grouped together
    struct PriceLevel has store, drop {
        price: u64,                    // The price for this level
        orders: vector<Order>,         // List of all orders at this price
        total_size: u64,               // Sum of all unfilled orders
    }

    /// Order Book
    /// The main structure holding all buy and sell orders
    struct OrderBook<phantom Base, phantom Quote> has key {
        // BUY SIDE (Bids) - Sorted from HIGHEST to LOWEST
        // Example: [$11.50, $11.20, $11.00]
        buy_orders: vector<PriceLevel>,
        
        // SELL SIDE (Asks) - Sorted from LOWEST to HIGHEST  
        // Example: [$11.80, $12.00, $12.50]
        sell_orders: vector<PriceLevel>,
        
        // Counter for unique order IDs
        next_order_id: u64,
        
        // Escrow: Coins locked while orders are active
        base_escrow: Coin<Base>,        // Coins being sold
        quote_escrow: Coin<Quote>,      // Money to buy with
        
        // Events for logging trades
        trade_events: EventHandle<TradeEvent>,
    }

    /// Trade Event
    /// Emitted every time a trade happens
    struct TradeEvent has store, drop {
        maker_order_id: u64,
        taker_order_id: u64,
        price: u64,
        size: u64,
        timestamp: u64,
    }

    // ============================================
    // STEP 4: INITIALIZE THE ORDER BOOK
    // This creates an empty order book
    // ============================================
    
    public entry fun initialize<Base, Quote>(creator: &signer) {
        let creator_addr = signer::address_of(creator);
        
        // Check if order book already exists
        assert!(
            !exists<OrderBook<Base, Quote>>(creator_addr),
            E_ALREADY_INITIALIZED
        );

        // Create empty order book
        move_to(creator, OrderBook<Base, Quote> {
            buy_orders: vector::empty<PriceLevel>(),
            sell_orders: vector::empty<PriceLevel>(),
            next_order_id: 1,
            base_escrow: coin::zero<Base>(),
            quote_escrow: coin::zero<Quote>(),
            trade_events: account::new_event_handle<TradeEvent>(creator),
        });
    }

    // ============================================
    // STEP 5: PLACE A BUY ORDER
    // User wants to BUY Base coins with Quote coins
    // ============================================
    
    public entry fun place_buy_order<Base, Quote>(
        user: &signer,
        book_addr: address,
        price: u64,             // Price per coin
        size: u64,              // How many coins to buy
    ) acquires OrderBook {
        // Validate inputs
        assert!(price > 0, E_INVALID_PRICE);
        assert!(size > 0, E_INVALID_SIZE);
        assert!(exists<OrderBook<Base, Quote>>(book_addr), E_NOT_INITIALIZED);

        let user_addr = signer::address_of(user);
        let book = borrow_global_mut<OrderBook<Base, Quote>>(book_addr);

        // Calculate how much Quote currency is needed
        // FIXED: Proper calculation for 8 decimal tokens
        // For mixed decimals, you'll need to adjust this formula
        let quote_needed = (price * size) / 100000000;
        
        // Lock the Quote coins in escrow
        let quote_coins = coin::withdraw<Quote>(user, quote_needed);
        coin::merge(&mut book.quote_escrow, quote_coins);

        // Create the order
        let order = Order {
            order_id: book.next_order_id,
            user: user_addr,
            side: SIDE_BUY,
            price,
            size,
            filled_size: 0,
            timestamp: timestamp::now_microseconds(),
        };

        book.next_order_id = book.next_order_id + 1;

        // Try to match this order immediately
        let remaining_order = try_match_buy_order(book, order);

        // If not fully filled, add to order book
        if (remaining_order.size > remaining_order.filled_size) {
            add_buy_order_to_book(book, remaining_order);
        };
    }

    // ============================================
    // STEP 6: PLACE A SELL ORDER
    // User wants to SELL Base coins for Quote coins
    // ============================================
    
    public entry fun place_sell_order<Base, Quote>(
        user: &signer,
        book_addr: address,
        price: u64,
        size: u64,
    ) acquires OrderBook {
        assert!(price > 0, E_INVALID_PRICE);
        assert!(size > 0, E_INVALID_SIZE);
        assert!(exists<OrderBook<Base, Quote>>(book_addr), E_NOT_INITIALIZED);

        let user_addr = signer::address_of(user);
        let book = borrow_global_mut<OrderBook<Base, Quote>>(book_addr);

        // Lock the Base coins being sold
        let base_coins = coin::withdraw<Base>(user, size);
        coin::merge(&mut book.base_escrow, base_coins);

        // Create the order
        let order = Order {
            order_id: book.next_order_id,
            user: user_addr,
            side: SIDE_SELL,
            price,
            size,
            filled_size: 0,
            timestamp: timestamp::now_microseconds(),
        };

        book.next_order_id = book.next_order_id + 1;

        // Try to match immediately
        let remaining_order = try_match_sell_order(book, order);

        // If not fully filled, add to book
        if (remaining_order.size > remaining_order.filled_size) {
            add_sell_order_to_book(book, remaining_order);
        };
    }

    // ============================================
    // STEP 7: MATCHING ENGINE - BUY ORDERS
    // This is the "brain" that matches buyers with sellers
    // ============================================
    
    fun try_match_buy_order<Base, Quote>(
        book: &mut OrderBook<Base, Quote>,
        buy_order: Order,
    ): Order {
        // A buy order matches with sell orders
        // We match from LOWEST sell price first (best for buyer)
        
        let mut_order = buy_order;
        let i = 0;
        
        loop {
            if (i >= vector::length(&book.sell_orders)) break;
            if (mut_order.filled_size >= mut_order.size) break;
            
            let can_match = {
                let price_level = vector::borrow(&book.sell_orders, i);
                mut_order.price >= price_level.price
            };
            
            if (can_match) {
                // Perform matching at this level
                let price_level = vector::borrow_mut(&mut book.sell_orders, i);
                mut_order = match_at_level_inline(
                    &mut book.base_escrow,
                    &mut book.quote_escrow,
                    &mut book.trade_events,
                    price_level,
                    mut_order,
                    true
                );
            } else {
                break
            };

            i = i + 1;
        };

        // Clean up empty price levels
        remove_empty_price_levels(&mut book.sell_orders);

        mut_order
    }

    fun try_match_sell_order<Base, Quote>(
        book: &mut OrderBook<Base, Quote>,
        sell_order: Order,
    ): Order {
        // A sell order matches with buy orders
        // We match from HIGHEST buy price first (best for seller)
        
        let mut_order = sell_order;
        let i = 0;
        
        loop {
            if (i >= vector::length(&book.buy_orders)) break;
            if (mut_order.filled_size >= mut_order.size) break;
            
            let can_match = {
                let price_level = vector::borrow(&book.buy_orders, i);
                mut_order.price <= price_level.price
            };
            
            if (can_match) {
                let price_level = vector::borrow_mut(&mut book.buy_orders, i);
                mut_order = match_at_level_inline(
                    &mut book.base_escrow,
                    &mut book.quote_escrow,
                    &mut book.trade_events,
                    price_level,
                    mut_order,
                    false
                );
            } else {
                break
            };

            i = i + 1;
        };

        remove_empty_price_levels(&mut book.buy_orders);

        mut_order
    }

    // Matching function
    fun match_at_level_inline<Base, Quote>(
        base_escrow: &mut Coin<Base>,
        quote_escrow: &mut Coin<Quote>,
        trade_events: &mut EventHandle<TradeEvent>,
        price_level: &mut PriceLevel,
        incoming_order: Order,
        incoming_is_buy: bool,
    ): Order {
        let order_idx = 0;
        let orders_len = vector::length(&price_level.orders);
        let mut_incoming = incoming_order;

        while (order_idx < orders_len && 
               mut_incoming.filled_size < mut_incoming.size) {
            
            let existing_order = vector::borrow_mut(&mut price_level.orders, order_idx);
            
            // How much can we trade?
            let incoming_remaining = mut_incoming.size - mut_incoming.filled_size;
            let existing_remaining = existing_order.size - existing_order.filled_size;
            
            let trade_size = if (incoming_remaining < existing_remaining) {
                incoming_remaining
            } else {
                existing_remaining
            };

            // Update fill amounts
            mut_incoming.filled_size = mut_incoming.filled_size + trade_size;
            existing_order.filled_size = existing_order.filled_size + trade_size;
            price_level.total_size = price_level.total_size - trade_size;

            // Execute trade inline
            let base_amount = trade_size;
            let quote_amount = (price_level.price * trade_size) / 100000000;

            if (incoming_is_buy) {
                // Taker is buying, maker is selling
                let base_coins = coin::extract(base_escrow, base_amount);
                coin::deposit(mut_incoming.user, base_coins);
                
                let quote_coins = coin::extract(quote_escrow, quote_amount);
                coin::deposit(existing_order.user, quote_coins);
            } else {
                // Taker is selling, maker is buying
                let base_coins = coin::extract(base_escrow, base_amount);
                coin::deposit(existing_order.user, base_coins);
                
                let quote_coins = coin::extract(quote_escrow, quote_amount);
                coin::deposit(mut_incoming.user, quote_coins);
            };

            // Emit trade event
            event::emit_event(trade_events, TradeEvent {
                maker_order_id: existing_order.order_id,
                taker_order_id: mut_incoming.order_id,
                price: price_level.price,
                size: trade_size,
                timestamp: timestamp::now_microseconds(),
            });

            order_idx = order_idx + 1;
        };

        mut_incoming
    }

    // ============================================
    // STEP 11: ADD ORDER TO BOOK
    // If order wasn't fully matched, add it to the book
    // ============================================
    
    fun add_buy_order_to_book<Base, Quote>(
        book: &mut OrderBook<Base, Quote>,
        order: Order,
    ) {
        let price = order.price;
        let remaining_size = order.size - order.filled_size;

        // Find the right place to insert (keep sorted high to low)
        let i = 0;
        let len = vector::length(&book.buy_orders);
        let inserted = false;

        while (i < len) {
            let price_level = vector::borrow_mut(&mut book.buy_orders, i);
            
            if (price == price_level.price) {
                // Price level exists, add order to it
                vector::push_back(&mut price_level.orders, order);
                price_level.total_size = price_level.total_size + remaining_size;
                inserted = true;
                break
            } else if (price > price_level.price) {
                // Insert new price level here
                let new_level = PriceLevel {
                    price,
                    orders: vector::singleton(order),
                    total_size: remaining_size,
                };
                vector::insert(&mut book.buy_orders, i, new_level);
                inserted = true;
                break
            };

            i = i + 1;
        };

        // If not inserted, add at end
        if (!inserted) {
            let new_level = PriceLevel {
                price,
                orders: vector::singleton(order),
                total_size: remaining_size,
            };
            vector::push_back(&mut book.buy_orders, new_level);
        };
    }

    fun add_sell_order_to_book<Base, Quote>(
        book: &mut OrderBook<Base, Quote>,
        order: Order,
    ) {
        let price = order.price;
        let remaining_size = order.size - order.filled_size;

        // Find right place (keep sorted low to high)
        let i = 0;
        let len = vector::length(&book.sell_orders);
        let inserted = false;

        while (i < len) {
            let price_level = vector::borrow_mut(&mut book.sell_orders, i);
            
            if (price == price_level.price) {
                vector::push_back(&mut price_level.orders, order);
                price_level.total_size = price_level.total_size + remaining_size;
                inserted = true;
                break
            } else if (price < price_level.price) {
                let new_level = PriceLevel {
                    price,
                    orders: vector::singleton(order),
                    total_size: remaining_size,
                };
                vector::insert(&mut book.sell_orders, i, new_level);
                inserted = true;
                break
            };

            i = i + 1;
        };

        if (!inserted) {
            let new_level = PriceLevel {
                price,
                orders: vector::singleton(order),
                total_size: remaining_size,
            };
            vector::push_back(&mut book.sell_orders, new_level);
        };
    }

    // ============================================
    // STEP 12: HELPER FUNCTIONS
    // ============================================
    
    fun remove_empty_price_levels(price_levels: &mut vector<PriceLevel>) {
        let i = 0;
        while (i < vector::length(price_levels)) {
            let level = vector::borrow(price_levels, i);
            if (level.total_size == 0) {
                vector::remove(price_levels, i);
            } else {
                i = i + 1;
            };
        };
    }

    // ============================================
    // STEP 13: VIEW FUNCTIONS
    // Query the order book state
    // ============================================
    
    #[view]
    public fun get_best_bid<Base, Quote>(book_addr: address): u64 acquires OrderBook {
        let book = borrow_global<OrderBook<Base, Quote>>(book_addr);
        if (vector::is_empty(&book.buy_orders)) {
            return 0
        };
        let top_level = vector::borrow(&book.buy_orders, 0);
        top_level.price
    }

    #[view]
    public fun get_best_ask<Base, Quote>(book_addr: address): u64 acquires OrderBook {
        let book = borrow_global<OrderBook<Base, Quote>>(book_addr);
        if (vector::is_empty(&book.sell_orders)) {
            return 0
        };
        let top_level = vector::borrow(&book.sell_orders, 0);
        top_level.price
    }

    #[view]
    public fun get_spread<Base, Quote>(book_addr: address): u64 acquires OrderBook {
        let best_bid = get_best_bid<Base, Quote>(book_addr);
        let best_ask = get_best_ask<Base, Quote>(book_addr);
        
        if (best_bid == 0 || best_ask == 0) {
            return 0
        };
        
        best_ask - best_bid
    }

    #[view]
    public fun get_book_depth<Base, Quote>(
        book_addr: address,
        levels: u64,
    ): (vector<u64>, vector<u64>, vector<u64>, vector<u64>) acquires OrderBook {
        let book = borrow_global<OrderBook<Base, Quote>>(book_addr);
        
        let buy_prices = vector::empty<u64>();
        let buy_sizes = vector::empty<u64>();
        let sell_prices = vector::empty<u64>();
        let sell_sizes = vector::empty<u64>();

        // Get buy side
        let i = 0;
        let buy_len = vector::length(&book.buy_orders);
        while (i < levels && i < buy_len) {
            let level = vector::borrow(&book.buy_orders, i);
            vector::push_back(&mut buy_prices, level.price);
            vector::push_back(&mut buy_sizes, level.total_size);
            i = i + 1;
        };

        // Get sell side
        i = 0;
        let sell_len = vector::length(&book.sell_orders);
        while (i < levels && i < sell_len) {
            let level = vector::borrow(&book.sell_orders, i);
            vector::push_back(&mut sell_prices, level.price);
            vector::push_back(&mut sell_sizes, level.total_size);
            i = i + 1;
        };

        (buy_prices, buy_sizes, sell_prices, sell_sizes)
    }
}

// ============================================
// HOW TO USE FOR TOKEN-TO-TOKEN TRADING
// ============================================
/*

EXAMPLE: Trading APT for TestUSDC

1. Deploy both CLOB and TestUSDC modules
2. Initialize TestUSDC and mint tokens
3. Initialize order book with type args:
   --type-args 0x1::aptos_coin::AptosCoin 0xaa4efc5f6235612f916dbb2ba356876e740505113ac0062da07e64e41618422f::TestUSDC::TestUSDC

4. Place orders with proper decimal handling:
   - APT has 8 decimals: 1 APT = 100,000,000
   - USDC typically has 6 decimals: 1 USDC = 1,000,000
   
5. Example: Buy 1 APT at $10 per APT
   price: 10,000,000 (10 USDC with 6 decimals)
   size: 100,000,000 (1 APT with 8 decimals)
   quote_needed = (10,000,000 * 100,000,000) / 100,000,000 = 10,000,000 (10 USDC)

NOTE: This calculation works when both tokens use 8 decimals.
For mixed decimals (APT=8, USDC=6), adjust the formula accordingly.

*/