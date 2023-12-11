


#[starknet::contract]
mod LayerAkira {
    use kurosawa_akira::FundsTraits::PoseidonHash;
    use starknet::{ContractAddress, get_caller_address};

    use kurosawa_akira::WithdrawComponent::withdraw_component::InternalWithdrawable;
    use starknet::{get_contract_address};
    
   
    
    use kurosawa_akira::ExchangeBalanceComponent::exchange_balance_logic_component::InternalExchangeBalanceble;
    use kurosawa_akira::ExchangeBalanceComponent::exchange_balance_logic_component as  exchange_balance_logic_component;
    use kurosawa_akira::SignerComponent::signer_logic_component as  signer_logic_component;
    use kurosawa_akira::DepositComponent::deposit_component as  deposit_component;
    use kurosawa_akira::WithdrawComponent::withdraw_component as withdraw_component;
    use kurosawa_akira::NonceComponent::nonce_component as nonce_component;
    use kurosawa_akira::RouterComponent::router_component as router_component;
    use kurosawa_akira::SafeTradeComponent::safe_trade_component as safe_trade_component;
    use kurosawa_akira::UnSafeTradeComponent::unsafe_trade_component as unsafe_trade_component;
    use kurosawa_akira::utils::SlowModeLogic::SlowModeDelay;
    use kurosawa_akira::WithdrawComponent::SignedWithdraw;
    use kurosawa_akira::Order::SignedOrder;

    use kurosawa_akira::SafeTradeComponent::safe_trade_component::InternalSafeTradable;
    use kurosawa_akira::UnSafeTradeComponent::unsafe_trade_component::InternalUnSafeTradable;
    
    use router_component::InternalRoutable;
    
    
    component!(path: exchange_balance_logic_component,storage: balancer_s, event:BalancerEvent);
    component!(path: signer_logic_component,storage: signer_s, event:SignerEvent);
    component!(path: deposit_component,storage: deposit_s, event:DepositEvent);
    component!(path: withdraw_component,storage: withdraw_s, event:WithdrawEvent);    
    component!(path: nonce_component, storage: nonce_s, event:NonceEvent);
    component!(path: router_component, storage: router_s, event:RouterEvent);
    component!(path: safe_trade_component, storage: safe_trade_s, event:SafeTradeEvent);
    component!(path: unsafe_trade_component, storage: unsafe_trade_s, event:UnSafeTradeEvent);

    


    #[abi(embed_v0)]
    impl ExchangeBalancebleImpl = exchange_balance_logic_component::ExchangeBalanceble<ContractState>;
    #[abi(embed_v0)]
    impl DepositableImpl = deposit_component::Depositable<ContractState>;
    #[abi(embed_v0)]
    impl SignableImpl = signer_logic_component::Signable<ContractState>;
    #[abi(embed_v0)]
    impl WithdrawableImpl = withdraw_component::Withdrawable<ContractState>;
    #[abi(embed_v0)]
    impl NonceableImpl = nonce_component::Nonceable<ContractState>;
    #[abi(embed_v0)]
    impl RoutableImpl = router_component::Routable<ContractState>;
    #[abi(embed_v0)]
    impl SafeTradableImpl = safe_trade_component::SafeTradable<ContractState>;
    #[abi(embed_v0)]
    impl UnSafeTradableImpl = unsafe_trade_component::UnSafeTradable<ContractState>;



    #[storage]
    struct Storage {
        #[substorage(v0)]
        balancer_s: exchange_balance_logic_component::Storage,
        #[substorage(v0)]
        deposit_s: deposit_component::Storage,
        #[substorage(v0)]
        signer_s: signer_logic_component::Storage,
        #[substorage(v0)]
        withdraw_s: withdraw_component::Storage,
        #[substorage(v0)]
        nonce_s: nonce_component::Storage,
        #[substorage(v0)]
        router_s: router_component::Storage,
        #[substorage(v0)]
        safe_trade_s: safe_trade_component::Storage,
        #[substorage(v0)]
        unsafe_trade_s: unsafe_trade_component::Storage,

        max_slow_mode_delay:SlowModeDelay,
        max_withdraw_action_cost:u32,

        exchange_invokers:LegacyMap::<ContractAddress,bool>
    }

    //  
    #[constructor]
    fn constructor(ref self: ContractState,
                wrapped_native_token:ContractAddress,
                fee_recipient:ContractAddress,
                max_slow_mode_delay:SlowModeDelay, 
                withdraw_max_action_cost:u32,
                exchange_invoker:ContractAddress) {
        self.max_slow_mode_delay.write(max_slow_mode_delay);
        self.max_withdraw_action_cost.write(withdraw_max_action_cost);
        self.balancer_s.initializer(fee_recipient, wrapped_native_token, 1000);
        self.withdraw_s.initializer(max_slow_mode_delay, withdraw_max_action_cost);
        self.exchange_invokers.write(exchange_invoker, true);
        // 0.2 eth, punishment factor == 10_000 bips
        self.router_s.initializer(max_slow_mode_delay, wrapped_native_token, 200_000_000_000_000_000, 10_000);
    }

    #[external(v0)]
    fn apply_withdraw(ref self: ContractState, signed_withdraw: SignedWithdraw, gas_price:u256) {
        assert(self.exchange_invokers.read(get_caller_address()), 'Only whitelisted invokers'); 
        self.withdraw_s.apply_withdraw(signed_withdraw, gas_price);
        self.balancer_s.latest_gas.write(gas_price);
    }

    #[external(v0)]
    fn apply_safe_trade(ref self: ContractState, taker_orders:Array<SignedOrder>, maker_orders: Array<SignedOrder>, iters:Array<(u8,bool)>, gas_price:u256) {
        assert(self.exchange_invokers.read(get_caller_address()), 'Only whitelisted invokers'); 
        self.safe_trade_s.apply_trades(taker_orders, maker_orders, iters, gas_price);
        self.balancer_s.latest_gas.write(gas_price);
    }

    #[external(v0)]
    fn apply_unsafe_trade(ref self: ContractState, taker_order:SignedOrder, maker_orders: Array<SignedOrder>, total_amount_matched:u256,  gas_price:u256) -> bool {
        assert(self.exchange_invokers.read(get_caller_address()), 'Only whitelisted invokers');
        let res = self.unsafe_trade_s.apply_trades_simple(taker_order, maker_orders, total_amount_matched, gas_price);
        self.balancer_s.latest_gas.write(gas_price);
        return res;
    }



    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        BalancerEvent: exchange_balance_logic_component::Event,
        DepositEvent: deposit_component::Event,
        SignerEvent: signer_logic_component::Event,
        WithdrawEvent: withdraw_component::Event,
        
        NonceEvent: nonce_component::Event,
        RouterEvent: router_component::Event,
        SafeTradeEvent: safe_trade_component::Event,
        UnSafeTradeEvent: unsafe_trade_component::Event,
    }

}
