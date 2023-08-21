#[contract]
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

    #[external]
    fn apply_exchange_events(serialized_exchange_events: Array::<felt252>) {
        let caller = get_caller_address();
        let this = get_contract_address();
        assert(caller == _exchange_address::read(), 'only for exchange');
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

    fn _mint(to: ContractAddress, amount: u256, token: ContractAddress) {
        _total_supply::write(token, _total_supply::read(token) + amount);
        _balance::write((token, to), _balance::read((token, to)) + amount);
    }

    fn _burn(from: ContractAddress, amount: u256, token: ContractAddress) {
        _total_supply::write(token, _total_supply::read(token) - amount);
        _balance::write((token, from), _balance::read((token, from)) - amount);
    }

    #[view]
    fn totalSupply(token: ContractAddress) -> u256 {
        _total_supply::read(token)
    }

    #[view]
    fn balanceOf(_address: ContractAddress, token: ContractAddress) -> u256 {
        _balance::read((token, _address))
    }

    fn _balance_write(token_user: (ContractAddress, ContractAddress), amount: u256) {
        _balance::write(token_user, amount);
    }

    fn _balance_read(token_user: (ContractAddress, ContractAddress)) -> u256 {
        _balance::read(token_user)
    }

    fn _filled_amount_write(hash: felt252, amount: u256) {
        _filled_amount::write(hash, amount);
    }

    fn _filled_amount_read(hash: felt252) -> u256 {
        _filled_amount::read(hash)
    }


    #[event]
    fn apply_transaction_started() {}
    #[event]
    fn apply_deposit_started() {}
    #[event]
    fn apply_withdraw_started() {}
    #[event]
    fn mathing_amount_event(amount: u256) {}
    #[event]
    fn matching_price_event(amount: u256) {}
    #[event]
    fn price_event(amount: u256) {}
    #[event]
    fn order_event(order: Order) {}
    #[event]
    fn user_balance_snapshot(user_address: ContractAddress, token: ContractAddress, balance: u256) {}
    #[event]
    fn jnfglksjrnglskejrnglskerjgnselkrjgns(amount: u256) {}
}
