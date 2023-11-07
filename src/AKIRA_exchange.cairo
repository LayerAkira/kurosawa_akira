#[starknet::contract]
mod AKIRA_exchange {
    use starknet::ContractAddress;
    use starknet::get_caller_address;
    use starknet::info::get_block_number;
    use starknet::info::get_contract_address;
    use serde::Serde;
    use option::OptionTrait;
    use array::ArrayTrait;
    use kurosawa_akira::ExchangeEntityStructures::ExchangeEntity::ExchangeEntity;
    use kurosawa_akira::ExchangeEntityStructures::Entities::TradeEntity::Trade;
    use kurosawa_akira::ExchangeEntityStructures::Entities::DepositEntity::Deposit;
    use kurosawa_akira::ExchangeEntityStructures::Entities::WithdrawEntity::Withdraw;
    use kurosawa_akira::ExchangeEntityStructures::Entities::WithdrawEntity::IWithdrawContractDispatcher;
    use kurosawa_akira::ExchangeEntityStructures::Entities::WithdrawEntity::IWithdrawContractDispatcherTrait;
    use kurosawa_akira::ExchangeEntityStructures::Entities::DepositEntity::IDepositContractDispatcher;
    use kurosawa_akira::ExchangeEntityStructures::Entities::DepositEntity::IDepositContractDispatcherTrait;
    use kurosawa_akira::ExchangeEntityStructures::Entities::SafeTradeLogic::ISafeTradeLogicDispatcher;
    use kurosawa_akira::ExchangeEntityStructures::Entities::SafeTradeLogic::ISafeTradeLogicDispatcherTrait;
    use kurosawa_akira::ExchangeBalance::IExchangeBalanceDispatcher;
    use kurosawa_akira::ExchangeBalance::IExchangeBalanceDispatcherTrait;


    #[storage]
    struct Storage {
        _name: felt252,
        exchange_invoker: ContractAddress,
        exchange_address: ContractAddress,
        balance_logic: ContractAddress,
        nonce_logic: ContractAddress,
        deposit_logic: ContractAddress,
        safe_trade_logic: ContractAddress,
        withdraw_logic: ContractAddress,
        batch_number: u256,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        exchange_invoker: ContractAddress,
        exchange_address: ContractAddress,
        balance_logic: ContractAddress,
        nonce_logic: ContractAddress,
        deposit_logic: ContractAddress,
        safe_trade_logic: ContractAddress,
        withdraw_logic: ContractAddress,
    ) {
        self.exchange_invoker.write(exchange_invoker);
        self.exchange_address.write(exchange_address);
        self.balance_logic.write(balance_logic);
        self.nonce_logic.write(nonce_logic);
        self.deposit_logic.write(deposit_logic);
        self.safe_trade_logic.write(safe_trade_logic);
        self.withdraw_logic.write(withdraw_logic);
    }

    //ENTITIES LOOP

    #[external(v0)]
    fn apply_exchange_entities(
        ref self: ContractState,
        serialized_exchange_entities: Array::<felt252>,
        batch_number: u256,
        cur_gas_price: u256,
    ) {
        let caller = get_caller_address();
        assert(caller == self.exchange_address.read(), 'only for exchange');
        assert(batch_number == self.batch_number.read(), 'wrong batch number');
        IExchangeBalanceDispatcher { contract_address: self.balance_logic.read() }
            .set_cur_gas_price(cur_gas_price);
        let mut span = serialized_exchange_entities.span();
        let exchange_entities: Array<ExchangeEntity> = Serde::<
            Array<ExchangeEntity>
        >::deserialize(ref span)
            .unwrap();
        _exchange_entities_loop(ref self, exchange_entities);
    }

    fn _exchange_entities_loop(
        ref self: ContractState, exchange_entities: Array::<ExchangeEntity>
    ) {
        let mut current_index = 0;
        let last_ind = exchange_entities.len();
        loop {
            if (current_index == last_ind) {
                break true;
            }
            let entity: ExchangeEntity = *exchange_entities[current_index];
            match entity {
                ExchangeEntity::DepositApply(x) => {
                    IDepositContractDispatcher { contract_address: self.deposit_logic.read() }
                        .apply_pending_deposit(x);
                },
                ExchangeEntity::Trade(x) => { apply_trade_event(ref self, x); },
                ExchangeEntity::SignedWithdraw(x) => {
                    IWithdrawContractDispatcher { contract_address: self.withdraw_logic.read() }
                        .apply_withdraw(x);
                },
            }
            current_index += 1;
        };
    }

    fn apply_trade_event(ref self: ContractState, trade: Trade) {
        ISafeTradeLogicDispatcher { contract_address: self.safe_trade_logic.read() }
            .apply_trade_event(trade);
    }

    fn get_pending_deposit(self: @ContractState) {}
    fn set_pending_deposit(ref self: ContractState) {}
    fn request_cancellation_pending(ref self: ContractState) {}
    fn cancel_pending_deposit(ref self: ContractState) {}
    fn apply_pending_deposit(ref self: ContractState) {}
    fn request_onchain_withdraw(ref self: ContractState) {}
    fn make_onchain_withdraw(ref self: ContractState) {}
    fn cancel_onchain_withdraw_request(ref self: ContractState) {}
    fn apply_withdraw(ref self: ContractState) {}
    fn apply_increase_nonce(ref self: ContractState) {}


    // EVENTS

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {}
}
