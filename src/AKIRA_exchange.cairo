#[starknet::contract]
mod AKIRA_exchange {
    use starknet::ContractAddress;
    use starknet::get_caller_address;
    use starknet::info::get_block_number;
    use starknet::info::get_contract_address;
    use serde::Serde;
    use option::OptionTrait;
    use array::ArrayTrait;
    use kurosawa_akira::ExchangeEventStructures::ExchangeEvent::ExchangeEvent;
    use kurosawa_akira::ExchangeEventStructures::ExchangeEvent::Applying;
    use kurosawa_akira::ExchangeEventStructures::Events::Order::Order;
    use kurosawa_akira::ExchangeEventStructures::Events::DepositEvent::Deposit;
    use kurosawa_akira::ExchangeEventStructures::Events::WithdrawEvent::Withdraw;
    use kurosawa_akira::ExchangeEventStructures::Events::DepositEvent::PendingImpl;
    use kurosawa_akira::ExchangeEventStructures::Events::DepositEvent::ZeroableImpl;
    use kurosawa_akira::ExchangeEventStructures::Events::FundsTraits::PoseidonHashImpl;

    #[storage]
    struct Storage {
        _name: felt252,
            _total_supply: LegacyMap::<ContractAddress, u256>,
        _balance: LegacyMap::<(ContractAddress, ContractAddress), u256>,
        _exchange_address: ContractAddress,
        _withdraw_block: LegacyMap::<ContractAddress, u64>,
        _filled_amount: LegacyMap::<felt252, u256>,
        _pending_deposits: LegacyMap::<felt252, Deposit>,
    }

    #[constructor]
    fn constructor(ref self: ContractState, _exchange_address0: ContractAddress) {
        self._name.write('AKIRA');
        self._exchange_address.write(_exchange_address0);
    }

    //EVENTS LOOP

    #[external(v0)]
    fn apply_exchange_events(
        ref self: ContractState, serialized_exchange_events: Array::<felt252>
    ) {
        let caller = get_caller_address();
        assert(caller == self._exchange_address.read(), 'only for exchange');
        let mut span = serialized_exchange_events.span();
        let exchange_events: Array<ExchangeEvent> = Serde::<Array<ExchangeEvent>>::deserialize(
            ref span
        )
            .unwrap();
        _exchange_events_loop(ref self, exchange_events);
    }

    fn _exchange_events_loop(
        ref contract_state: ContractState, exchange_events: Array::<ExchangeEvent>
    ) {
        let mut current_index = 0;
        let last_ind = exchange_events.len();
        loop {
            if (current_index == last_ind) {
                break true;
            }
            let event: ExchangeEvent = *exchange_events[current_index];
            event.apply(ref contract_state);
            current_index += 1;
        };
    }

    // PENDING

    #[external(v0)]
    fn set_deposit_pending(ref self: ContractState, deposit: Deposit) {
        deposit.set_pending(ref self);
    }

    // TOKEN

    fn _mint(ref self: ContractState, to: ContractAddress, amount: u256, token: ContractAddress) {
        self._total_supply.write(token, self._total_supply.read(token) + amount);
        self._balance.write((token, to), self._balance.read((token, to)) + amount);
    }

    fn _burn(ref self: ContractState, from: ContractAddress, amount: u256, token: ContractAddress) {
        self._total_supply.write(token, self._total_supply.read(token) - amount);
        self._balance.write((token, from), self._balance.read((token, from)) - amount);
    }

    // VIEW

    #[external(v0)]
    fn totalSupply(self: @ContractState, token: ContractAddress) -> u256 {
        self._total_supply.read(token)
    }

    #[external(v0)]
    fn balanceOf(
        self: @ContractState, _address: ContractAddress, token: ContractAddress
    ) -> u256 {
        self._balance.read((token, _address))
    }

    #[external(v0)]
    fn order_poseidon_hash(self: @ContractState, order: Order) -> felt252 {
        order.get_poseidon_hash()
    }
    #[external(v0)]
    fn deposit_poseidon_hash(self: @ContractState, deposit: Deposit) -> felt252 {
        deposit.get_poseidon_hash()
    }
    #[external(v0)]
    fn withdraw_poseidon_hash(self: @ContractState, withdraw: Withdraw) -> felt252 {
        withdraw.get_poseidon_hash()
    }

    #[external(v0)]
    fn check_deposit_pending_status(self: @ContractState, deposit: Deposit) -> bool {
        !self._pending_deposits.read(deposit.get_poseidon_hash()).is_zero()
    }

    // read and write

    fn _balance_write(
        ref self: ContractState, token_user: (ContractAddress, ContractAddress), amount: u256
    ) {
        self._balance.write(token_user, amount);
    }

    fn _balance_read(
        ref self: ContractState, token_user: (ContractAddress, ContractAddress)
    ) -> u256 {
        self._balance.read(token_user)
    }

    fn _filled_amount_write(ref self: ContractState, hash: felt252, amount: u256) {
        self._filled_amount.write(hash, amount);
    }

    fn _filled_amount_read(ref self: ContractState, hash: felt252) -> u256 {
        self._filled_amount.read(hash)
    }

    fn _pending_deposits_write(ref self: ContractState, hash: felt252, deposit: Deposit) {
        self._pending_deposits.write(hash, deposit);
    }

    fn _pending_deposits_read(ref self: ContractState, hash: felt252) -> Deposit {
        self._pending_deposits.read(hash)
    }



    // EVENTS

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        apply_transaction_started: apply_transaction_started,
        apply_deposit_started: apply_deposit_started,
        apply_withdraw_started: apply_withdraw_started,
        mathing_amount_event: mathing_amount_event,
        matching_price_event: matching_price_event,
        price_event: price_event,
        order_event: order_event,
        deposit_event: deposit_event,
        user_balance_snapshot: user_balance_snapshot,
        fdghdfghdfghdfghdfghdffgf: fdghdfghdfghdfghdfghdffgf,
    }
    #[derive(Drop, starknet::Event)]
    struct apply_transaction_started {}
    fn emit_apply_transaction_started(
        ref self: ContractState, _apply_transaction_started: apply_transaction_started
    ) {
        self.emit(Event::apply_transaction_started(_apply_transaction_started));
    }
    #[derive(Drop, starknet::Event)]
    struct apply_deposit_started {}
    fn emit_apply_deposit_started(
        ref self: ContractState, _apply_deposit_started: apply_deposit_started
    ) {
        self.emit(Event::apply_deposit_started(_apply_deposit_started));
    }
    #[derive(Drop, starknet::Event)]
    struct apply_withdraw_started {}
    fn emit_apply_withdraw_started(
        ref self: ContractState, _apply_withdraw_started: apply_withdraw_started
    ) {
        self.emit(Event::apply_withdraw_started(_apply_withdraw_started));
    }
    #[derive(Drop, starknet::Event)]
    struct mathing_amount_event {
        amount: u256
    }
    fn emit_mathing_amount_event(
        ref self: ContractState, _mathing_amount_event: mathing_amount_event
    ) {
        self.emit(Event::mathing_amount_event(_mathing_amount_event));
    }
    #[derive(Drop, starknet::Event)]
    struct matching_price_event {
        amount: u256
    }
    fn emit_matching_price_event(
        ref self: ContractState, _matching_price_event: matching_price_event
    ) {
        self.emit(Event::matching_price_event(_matching_price_event));
    }
    #[derive(Drop, starknet::Event)]
    struct price_event {
        amount: u256
    }
    fn emit_price_event(ref self: ContractState, _price_event: price_event) {
        self.emit(Event::price_event(_price_event));
    }
    #[derive(Drop, starknet::Event)]
    struct order_event {
        order: Order
    }
    fn emit_order_event(ref self: ContractState, _order_event: order_event) {
        self.emit(Event::order_event(_order_event));
    }
    #[derive(Drop, starknet::Event)]
    struct deposit_event {
        deposit: Deposit
    }
    fn emit_deposit_event(ref self: ContractState, _deposit_event: deposit_event) {
        self.emit(Event::deposit_event(_deposit_event));
    }
    #[derive(Drop, starknet::Event)]
    struct user_balance_snapshot {
        user_address: ContractAddress,
        token: ContractAddress,
        balance: u256,
    }
    fn emit_user_balance_snapshot(
        ref self: ContractState, _user_balance_snapshot: user_balance_snapshot
    ) {
        self.emit(Event::user_balance_snapshot(_user_balance_snapshot));
    }
    #[derive(Drop, starknet::Event)]
    struct fdghdfghdfghdfghdfghdffgf {}
}
