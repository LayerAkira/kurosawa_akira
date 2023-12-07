


#[starknet::contract]
mod LayerAkira {
    use starknet::{get_contract_address, ContractAddress};
    use kurosawa_akira::SafeTradeComponent::safe_trade_component::InternalSafeTradable;
    use kurosawa_akira::ExchangeBalanceComponent::exchange_balance_logic_component::InternalExchangeBalanceble;
    use kurosawa_akira::ExchangeBalanceComponent::exchange_balance_logic_component as  exchange_balance_logic_component;
    use kurosawa_akira::SignerComponent::signer_logic_component as  signer_logic_component;
    use kurosawa_akira::DepositComponent::deposit_component as  deposit_component;
    use kurosawa_akira::WithdrawComponent::withdraw_component as withdraw_component;
    use kurosawa_akira::NonceComponent::nonce_component as nonce_component;
    use kurosawa_akira::RouterComponent::router_component as router_component;
    use kurosawa_akira::SafeTradeComponent::safe_trade_component as safe_trade_component;
    use kurosawa_akira::UnSafeTradeComponent::unsafe_trade_component as unsafe_trade_component;

    // use exchange_balance_logic_component::InternalExchangeBalancebleImpl;
    
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
    }
    // #[constructor]
    // fn constructor(ref self: ContractState, fee_recipient:ContractAddress,wrapped_native_token:ContractAddress) {

    #[constructor]
    fn constructor(ref self: ContractState) {
        // get_contract_address()
        // self.balancer_s.initializer(fee_recipient,wrapped_native_token,

        // )
        // self.balancer_s.wrapped_native_token.write(1.try_into().unwrap());
        // let ETH_address: ContractAddress =
        //     0x049D36570D4e46f48e99674bd3fcc84644DdD6b96F7C741B1562B82f9e004dC7
        //     .try_into()
        //     .unwrap();
        // self.ssc_s.name.write('Spotify');
        // self
        //     .ssc_s
        //     .sub_id_to_sub_info
        //     .write(
        //         0,
        //         Subscription {
        //             payment_amount: 1,
        //             payment_token: ETH_address,
        //             sub_period_in_seconds: 1000,
        //             sub_id: 0,
        //             max_periods_allowed: 5,
        //         }
        //     );
        // self.ssc_s.fee_recipient.write(get_contract_address());
        // self.ssc_s.bips_reward.write(0);
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
