module TrainTicket::ticket {

    // Dependencies Imports
    use std::string::{String};
    use std::vector;
    use sui::transfer;
    use sui::object::{Self, UID, ID};
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::event;
    use sui::tx_context::{TxContext, sender};
    use sui::table::{Self, Table};
    use sui::bag::{Self, Bag};
    use sui::balance:: {Self, Balance};
    use sui::clock::{Clock, timestamp_ms};

    // Errors Definitions 
    const ERROR_INVALID_PRICE: u64 = 0;
    const ERROR_TIME_IS_UP: u64 = 1;
    const ERROR_INVALID_SEAT_NUMBER: u64 = 2;
    const ERROR_INCORRECT_TRAIN: u64 = 3;
    const ERROR_NOT_OWNER: u64 = 4;
    const ERROR_TIME_NOT_COMPLETED: u64 = 5;

    // === Structs ===
    
    // Represents a Train Station where funds and train IDs are tracked.
    struct Station has key, store {
        id: UID,
        balance: Balance<SUI>,
        consolidation: Table<String, Bag>
    }

    /// Represents a Train with details for booking.
    struct Train has key, store {
        id: UID,
        owner: ID,
        balance: Balance<SUI>,
        from: String,
        to: String,
        seat_num: u8,
        seat: Table<u8, address>,
        taken: vector<u8>,
        price: u64,
        start: u64,
        end: u64
    }

    /// Represents a Train Ticket.
    struct Ticket has key, store {
        id: UID,
        train: ID,
        owner: address,
        launch_time: u64,
        seat_no: u8
    }
    
    // Admin Capabilities
    struct AdminCap has key {
        id: UID
    }
    
    // Events Definitions
    struct TrainCreated has copy, drop {
        owner: ID,
        from: String,
        to: String,
        price: u64,
        start: u64,
        end: u64
    }
    
    // Initializer
    fun init(ctx: &mut TxContext) {
        transfer::share_object(Station {
            id: object::new(ctx),
            balance: balance::zero(),
            consolidation: table::new<String, Bag>(ctx)
        });

        transfer::transfer(AdminCap { id: object::new(ctx) }, sender(ctx));
    }

    // === Public Functions ===
    public fun new(
        _: &AdminCap,
        station: &mut Station,
        seats: u8,
        from_: String,
        to_: String,
        price_: u64,
        start_: u64,
        end_: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let id_ = object::new(ctx);
        let inner_ = object::uid_to_inner(&id_);
        new_bag(station, from_, ctx);
        let bag_ = table::borrow_mut(&mut station.consolidation, from_);
        if (!bag::contains(bag_, to_)) {
            bag::add<String, vector<ID>>(bag_, to_, vector::empty());
        };
        // Get coins vector from bag
        let train = bag::borrow_mut<String, vector<ID>>(bag_, to_);
        vector::push_back(train, inner_);
        
        let remaining_: u64 = ((end_) * (60)) + timestamp_ms(clock);
        let starts = ((start_) * (60)) + timestamp_ms(clock);
        
        // Share the train Object
        transfer::share_object(Train {
            id: id_,
            owner: inner_,
            balance: balance::zero(),
            from: from_,
            to: to_,
            seat_num: seats,
            seat: table::new(ctx),
            taken: vector::empty(),
            price: price_,
            start: starts,
            end: remaining_
        });

        event::emit(TrainCreated {
            owner: inner_,
            from: from_,
            to: to_,
            price: price_,
            start: starts,
            end: remaining_
        });
    }
    
    public fun buy(train: &mut Train, coin: Coin<SUI>, seat_no_: u8, clock: &Clock, ctx: &mut TxContext) {
        assert!(coin::value(&coin) >= train.price, ERROR_INVALID_PRICE);
        assert!(timestamp_ms(clock) < train.end, ERROR_TIME_IS_UP);
        assert!(seat_no_ <= train.seat_num && seat_no_ > 0, ERROR_INVALID_SEAT_NUMBER);
        assert!(!vector::contains(&train.taken, &seat_no_), ERROR_INVALID_SEAT_NUMBER);

        table::add(&mut train.seat, seat_no_, sender(ctx));
        vector::push_back(&mut train.taken, seat_no_);
        let balance_ = coin::into_balance(coin);
        balance::join(&mut train.balance, balance_);

        transfer::public_transfer(Ticket {
            id: object::new(ctx),
            train: train.owner,
            owner: sender(ctx),
            launch_time: train.end,
            seat_no: seat_no_
        }, sender(ctx));
    }

    public fun refund(
        train: &mut Train,
        ticket: Ticket,
        clock: &Clock,
        ctx: &mut TxContext
    ) : Coin<SUI> {
        assert!(sender(ctx) == ticket.owner, ERROR_NOT_OWNER);
        assert!(timestamp_ms(clock) < (ticket.launch_time - 3600), ERROR_TIME_IS_UP);
        assert!(ticket.train == train.owner, ERROR_INCORRECT_TRAIN);

        table::remove(&mut train.seat, ticket.seat_no);
        let (_bool, index) = vector::index_of(&train.taken, &ticket.seat_no);
        vector::remove(&mut train.taken, index);

        destroy_ticket(ticket);

        let balance_ = balance::split(&mut train.balance, train.price);
        let coin = coin::from_balance<SUI>(balance_, ctx);
        coin
    }

    public fun close_train(_: &AdminCap, station: &mut Station, train: Train, clock: &Clock) {
        assert!(timestamp_ms(clock) > train.end, ERROR_TIME_NOT_COMPLETED);

        let Train { id, owner, balance, from, to, seat_num: _, seat, taken, price: _, start: _, end: _ } = train;
        let _num = balance::join(&mut station.balance, balance);
        object::delete(id);

        let i: u64 = 0;
        let j: u64 = vector::length(&taken);
        while (i < j) {
            let index = vector::borrow(&mut taken, i);
            table::remove(&mut seat, *index);
            i = i + 1;
        };

        table::destroy_empty(seat);
        
        // Remove Train Id from the station
        let bag_ = table::borrow_mut<String, Bag>(&mut station.consolidation, from);
        let vector_ = bag::borrow_mut<String, vector<ID>>(bag_, to);

        let (_bool, index) = vector::index_of(vector_, &owner);
        // Remove from vector
        vector::remove(vector_, index);
    }

    // === View Functions ===
    public fun get_train(train: &Train) : (
        ID,
        u64,
        String,
        String,
        u8,
        vector<u8>,
        u64,
        u64,
        u64
    ) {
        let balance_ = balance::value(&train.balance);
        (
            train.owner,
            balance_,
            train.from,
            train.to,
            train.seat_num,
            train.taken,
            train.price,
            train.start,
            train.end
        )
    }

    public fun get_seats(train: &Train) : vector<u8> {
        train.taken
    }

    public fun get_seat_num(train: &Train) : u8 {
        train.seat_num
    }

    public fun get_consolidations(station: &Station, from: String, to: String) : vector<ID> {
        let bag_ = table::borrow<String, Bag>(&station.consolidation, from);
        let vector_ = bag::borrow<String, vector<ID>>(bag_, to);
        *vector_
    }

    // === Private Functions ===
    fun new_bag(station: &mut Station, from: String, ctx: &mut TxContext) {
        if (!table::contains(&station.consolidation, from)) {
            let bag_ = bag::new(ctx);
            table::add(&mut station.consolidation, from, bag_);
        }
    }

    fun destroy_ticket(ticket: Ticket) {
        let Ticket { id, train: _, owner: _, launch_time: _, seat_no: _ } = ticket;
        object::delete(id);
    }

    // === Test-Only Functions ===
    #[test_only]
    public fun test_init(ctx: &mut TxContext) {
        init(ctx);
    }

    #[test_only]
    public fun get_train_balance(train: &Train) : u64 {
        let value = balance::value(&train.balance);
        value
    }

    #[test_only]
    public fun get_station_balance(station: &Station) : u64 {
        let value = balance::value(&station.balance);
        value
    }
}
