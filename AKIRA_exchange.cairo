use starknet::ContractAddress;

#[abi]
trait IERC20 {
    #[view]
    fn name() -> felt252;

    #[view]
    fn symbol() -> felt252;

    #[view]
    fn decimals() -> u8;

    #[view]
    fn total_supply() -> u256;

    #[view]
    fn balanceOf(account: ContractAddress) -> u256;

    #[view]
    fn allowance(owner: ContractAddress, spender: ContractAddress) -> u256;

    #[external]
    fn transfer(recipient: ContractAddress, amount: u256) -> bool;

    #[external]
    fn transferFrom(sender: ContractAddress, recipient: ContractAddress, amount: u256) -> bool;

    #[external]
    fn approve(spender: ContractAddress, amount: u256) -> bool;
}



#[contract]
mod AKIRA_exchange {
    use super::IERC20DispatcherTrait;
    use super::IERC20Dispatcher;
    use starknet::ContractAddress;
    use starknet::get_caller_address;
    use starknet::info::get_block_number;
    use starknet::info::get_contract_address;
    use array::ArrayTrait;
    use traits::Into;
    use poseidon::poseidon_hash_span;
    use serde::Serde;
    use option::OptionTrait;
    use array::SpanTrait;
    struct Storage {
       _name: felt252,
       _total_supply: LegacyMap::<ContractAddress, u256>,
       _balance: LegacyMap::<(ContractAddress, ContractAddress), u256>,
       _exchange_address: ContractAddress,
       _withdraw_block: LegacyMap::<ContractAddress, u64>,
       _filled_amount: LegacyMap::<felt252, u256>,
    }

    #[constructor]
    fn constructor(_exchange_address0: ContractAddress) {
        _name::write('AKIRA');
        _exchange_address::write(_exchange_address0)
    }

    fn min(a: u256, b: u256) -> u256{
        if a > b{
            b
        }
        else{
            a
        }
    }

    #[derive(Copy, Drop, Serde, starknet::Store)]
    enum ExchangeEvent {
        Deposit: Deposit,
        Withdraw: Withdraw,
        Trade: Trade,
    }

    #[derive(Copy, Drop, Serde, starknet::Store)]
    struct Deposit {
        maker: ContractAddress,
        token: ContractAddress,
        amount: u256,
        validation_info: felt252,
    }

    #[derive(Copy, Drop, Serde, starknet::Store)]
    struct Withdraw {
        maker: ContractAddress,
        token: ContractAddress,
        amount: u256,
    }

    #[derive(Copy, Drop, Serde, starknet::Store)]
    struct Trade {
        maker_order: Order,
        maker_order_signature: u256,
        taker_order: Order,
        taker_order_signature: u256,
    }

    trait ApplyingTrade {
        fn apply(self: Trade);
    }

    #[external]
    fn get_order_hash(key: Order) -> felt252 {
            let mut serialized: Array<felt252> = ArrayTrait::new();
            Serde::<Order>::serialize(@key, ref serialized);
            let hashed_key: felt252 = poseidon_hash_span(serialized.span());
            hashed_key
    }

    fn validate_order(order: Order, order_hash: felt252) -> u256 {
        order.quantity - _filled_amount::read(order_hash)
    }

    fn rebalance_after_trade(is_maker_SELL_side: bool, trade: Trade, amount_maker: u256, amount_taker: u256){
        if is_maker_SELL_side {
            _balance::write((trade.maker_order.qty_address, trade.maker_order.maker), _balance::read((trade.maker_order.qty_address, trade.maker_order.maker)) - amount_maker);
            _balance::write((trade.taker_order.qty_address, trade.taker_order.maker), _balance::read((trade.taker_order.qty_address, trade.taker_order.maker)) + amount_maker);
            _balance::write((trade.maker_order.price_address, trade.maker_order.maker), _balance::read((trade.maker_order.price_address, trade.maker_order.maker)) + amount_taker);
            _balance::write((trade.taker_order.price_address, trade.taker_order.maker), _balance::read((trade.taker_order.price_address, trade.taker_order.maker)) - amount_taker);
        } else {
            _balance::write((trade.maker_order.qty_address, trade.maker_order.maker), _balance::read((trade.maker_order.qty_address, trade.maker_order.maker)) + amount_maker);
            _balance::write((trade.taker_order.qty_address, trade.taker_order.maker), _balance::read((trade.taker_order.qty_address, trade.taker_order.maker)) - amount_maker);
            _balance::write((trade.maker_order.price_address, trade.maker_order.maker), _balance::read((trade.maker_order.price_address, trade.maker_order.maker)) - amount_taker);
            _balance::write((trade.taker_order.price_address, trade.taker_order.maker), _balance::read((trade.taker_order.price_address, trade.taker_order.maker)) + amount_taker);
        }
    }

    impl ApplyingTradeImpl of ApplyingTrade {
        fn apply(self: Trade){
            let trade = self;

            apply_transaction_started();
            order_event(trade.maker_order);
            order_event(trade.taker_order);

            let maker_order_hash = get_order_hash(trade.maker_order);
            let taker_order_hash = get_order_hash(trade.taker_order);

            let maker_amount = validate_order(trade.maker_order, maker_order_hash);
            let taker_amount = validate_order(trade.taker_order, taker_order_hash);

            let mathing_amount: u256 = min(taker_amount,maker_amount);
            mathing_amount_event(mathing_amount);

            let matching_price: u256 = trade.maker_order.price;
            matching_price_event(matching_price);

            _filled_amount::write(maker_order_hash, _filled_amount::read(maker_order_hash) + mathing_amount);
            _filled_amount::write(taker_order_hash, _filled_amount::read(taker_order_hash) + mathing_amount);

            rebalance_after_trade(trade.maker_order.side, trade, mathing_amount, mathing_amount * matching_price);
        }
    }
    trait ApplyingDeposit {
        fn apply(self: Deposit);
    }

    impl ApplyingDepositImpl of ApplyingDeposit {
        fn apply(self: Deposit){
            _mint(self.maker, self.amount, self.token);
        }
    }

    trait ApplyingWithdraw {
        fn apply(self: Withdraw);
    }

    impl ApplyingWithdrawImpl of ApplyingWithdraw {
        fn apply(self: Withdraw){
            _burn(self.maker, self.amount, self.token);
            IERC20Dispatcher { contract_address: self.token }.transfer(self.maker, self.amount);
        }
    }

    trait ApplyingEvent{
        fn apply(self: ExchangeEvent);
    }

    impl ApplyingEventImpl of ApplyingEvent {
        fn apply(self: ExchangeEvent){
            match self {
                ExchangeEvent::Deposit(x) => {
                    x.apply();
                },
                ExchangeEvent::Withdraw(x) => {
                    x.apply();
                },
                ExchangeEvent::Trade(x) => {
                    x.apply();
                },
            }
        }
    }

    #[derive(Copy, Drop, Serde, starknet::Store)]
    struct Order {
        price: u256,
        quantity: u256,
        maker: ContractAddress,
        created_at: u256,
        order_id: u256,
        full_fill_only: bool,
        best_level_only: bool,
        post_only: bool,
        side: bool,
        status: u8,
        qty_address: ContractAddress,
        price_address: ContractAddress,
        order_type: bool,
    }

    #[external]
    fn apply_exchange_events(serialized_exchange_events: Array::<felt252>) {
        let caller = get_caller_address();
        let this = get_contract_address();
        assert(caller == _exchange_address::read(), 'only for exchange');
        // TODO deserialize
        let mut span = serialized_exchange_events.span();
        let exchange_events: Array<ExchangeEvent> = Serde::<Array<ExchangeEvent>>::deserialize(ref span).unwrap();
        _exchange_events_loop(exchange_events);
    }

    fn _exchange_events_loop(exchange_events: Array::<ExchangeEvent>) {
        let mut current_index = 0;
        let last_ind = exchange_events.len();
        loop {
            if (current_index == last_ind) {
                break true;
            }
            let event: ExchangeEvent = *exchange_events[current_index];
            event.apply();
            current_index += 1;
        };
    }

    #[view]
    fn name() -> felt252 {
        _name::read()
    }

    #[view]
    fn totalSupply(token: ContractAddress) -> u256 {
        _total_supply::read(token)
    }

    #[view]
    fn balanceOf(_address: ContractAddress, token: ContractAddress) -> u256 {
        _balance::read((token, _address))
    }

    #[view]
    fn get_block() -> u64 {
        get_block_number()
    }

    fn _mint(to: ContractAddress, amount: u256, token: ContractAddress) {
        _total_supply::write(token, _total_supply::read(token) + amount);
        _balance::write((token, to), _balance::read((token, to)) + amount);
    }

    fn _burn(from: ContractAddress, amount: u256, token: ContractAddress) {
        _total_supply::write(token, _total_supply::read(token) - amount);
        _balance::write((token, from), _balance::read((token, from)) - amount);
    }


    // #[external]
    // fn deposit(from: ContractAddress, amount: u256, token: ContractAddress) {
    //     let caller = get_caller_address();
    //     let this = get_contract_address();
    //     assert(caller == _exchange_address::read(), 'only for exchange');
    //     IERC20Dispatcher { contract_address: token }.transferFrom(from, this, amount);
    //     _mint(from, amount, token);
    // }
    //
    //
    // #[external]
    // fn withdraw_from_exchange(user: ContractAddress, amount: u256, token: ContractAddress) {
    //     let caller = get_caller_address();
    //     let this = get_contract_address();
    //     assert(caller == _exchange_address::read(), 'only for exchange');
    //     _burn(user, amount, token);
    //     IERC20Dispatcher { contract_address: token }.transfer(user, amount);
    // }

    //#[external]
    //fn apply_withdraw_via_contract(token: ContractAddress) {
    //    let caller = get_caller_address();
    //    let this = get_contract_address();
    //   let block_number = get_block_number();
    //    _withdraw_block::write(caller, block_number);
        // TODO send info to backend
    // }

    // #[external]
    // fn withdraw_from_contract(amount: u256, token: ContractAddress) {
    //     let caller = get_caller_address();
    //     let this = get_contract_address();
    //     let diff: u64 = 5;
    //     assert(_withdraw_block::read(caller) != 0, 'first apply');
    //     let real_diff = get_block_number() - _withdraw_block::read(caller);
    //     assert(real_diff >= diff, 'wait more blocks');
    //     _burn(caller, amount, token);
    //     IERC20Dispatcher { contract_address: token }.transfer(caller, amount);
    //     _withdraw_block::write(caller, 0);
    // }

    #[event]
    fn dfghdfghdfghdfghdsdsfgdfgdfgsdfddfdfggdfgfdfgdfggfghdfghdfdfdghdfg(amount: felt252) {}

    #[event]
    fn apply_transaction_started() {}
    #[event]
    fn mathing_amount_event(amount: u256) {}
    #[event]
    fn matching_price_event(amount: u256) {}
    #[event]
    fn price_event(amount: u256) {}
    #[event]
    fn ev_01(amount: u256) {}
    #[event]
    fn ev_02(address: ContractAddress) {}
    #[event]
    fn order_event(order: Order) {}

}
