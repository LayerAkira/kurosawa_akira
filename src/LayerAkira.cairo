
#[starknet::contract]
mod LayerAkira {
    use core::starknet::event::EventEmitter;
    use kurosawa_akira::NonceComponent::nonce_component::InternalNonceable;
    use starknet::{ContractAddress, get_caller_address, get_tx_info};

    use kurosawa_akira::WithdrawComponent::withdraw_component::InternalWithdrawable;
    use starknet::{get_contract_address};
    
    use kurosawa_akira::ExchangeBalanceComponent::exchange_balance_logic_component::InternalExchangeBalanceble;
    use kurosawa_akira::ExchangeBalanceComponent::exchange_balance_logic_component as  exchange_balance_logic_component;
    use kurosawa_akira::SignerComponent::signer_logic_component as  signer_logic_component;
    use kurosawa_akira::DepositComponent::deposit_component as  deposit_component;
    use kurosawa_akira::WithdrawComponent::withdraw_component as withdraw_component;
    use kurosawa_akira::NonceComponent::nonce_component as nonce_component;
    use kurosawa_akira::RouterComponent::router_component as router_component;
    use kurosawa_akira::EcosystemTradeComponent::ecosystem_trade_component as ecosystem_trade_component;
    use kurosawa_akira::utils::SlowModeLogic::SlowModeDelay;
    use kurosawa_akira::WithdrawComponent::{SignedWithdraw, Withdraw};
    use kurosawa_akira::Order::{SignedOrder, Order};
    use kurosawa_akira::NonceComponent::{SignedIncreaseNonce, IncreaseNonce};
    
    use kurosawa_akira::EcosystemTradeComponent::ecosystem_trade_component::InternalEcosystemTradable;
    
    use router_component::InternalRoutable;
    
    
    component!(path: exchange_balance_logic_component,storage: balancer_s, event:BalancerEvent);
    component!(path: signer_logic_component,storage: signer_s, event:SignerEvent);
    component!(path: deposit_component,storage: deposit_s, event:DepositEvent);
    component!(path: withdraw_component,storage: withdraw_s, event:WithdrawEvent);    
    component!(path: nonce_component, storage: nonce_s, event:NonceEvent);
    component!(path: router_component, storage: router_s, event:RouterEvent);
    component!(path: ecosystem_trade_component, storage: ecosystem_trade_s, event:EcosystemTradeEvent);
    
    

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
    impl EcosystemTradableImpl = ecosystem_trade_component::EcosystemTradable<ContractState>;
    
    

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
        ecosystem_trade_s: ecosystem_trade_component::Storage,
        
        max_slow_mode_delay:SlowModeDelay, // upper bound for all delayed actions
        exchange_invokers: LegacyMap::<ContractAddress, bool>,
        owner: ContractAddress, // owner of contact that have permissions to grant and revoke role for invokers and update slow mode 
        hash_lock:felt252,
        scheduled_taker_order:Order,
    }


    #[constructor]
    fn constructor(ref self: ContractState,
                wrapped_native_token:ContractAddress,
                fee_recipient:ContractAddress,
                max_slow_mode_delay:SlowModeDelay, 
                withdraw_action_cost:u32, // propably u16
                exchange_invoker:ContractAddress,
                min_to_route:u256, // minimum amount neccesary to start to provide 
                owner:ContractAddress) {
        self.max_slow_mode_delay.write(max_slow_mode_delay);

        self.balancer_s.initializer(fee_recipient, wrapped_native_token);
        self.withdraw_s.initializer(max_slow_mode_delay, withdraw_action_cost);
        self.exchange_invokers.write(exchange_invoker, true);
        self.owner.write(owner);
        self.router_s.initializer(max_slow_mode_delay, wrapped_native_token, min_to_route, 10_000);
        self.hash_lock.write(0);
    }

    #[external(v0)]
    fn update_exchange_invokers(ref self: ContractState, invoker:ContractAddress, enabled:bool) {
        assert!(self.owner.read() == get_caller_address(), "Access denied: update_exchange_invokers is only for the owner's use");
        self.exchange_invokers.write(invoker, enabled);
        self.emit(UpdateExchangeInvoker{invoker, enabled});
    }


    #[external(v0)]
    fn update_withdraw_component_params(ref self: ContractState, new_delay:SlowModeDelay) {
        assert!(self.owner.read() == get_caller_address(), "Access denied: update_withdraw_component_params is only for the owner's use");
        let max = self.max_slow_mode_delay.read();
        assert!(new_delay.block <= max.block && new_delay.ts <= max.ts, "Failed withdraw params update: new_delay <= max_slow_mode_delay");
        self.withdraw_s.delay.write(new_delay);
        self.emit(WithdrawComponentUpdate{new_delay});
    }

    #[external(v0)]
    fn update_fee_recipient(ref self: ContractState, new_fee_recipient: ContractAddress) {
        assert!(self.owner.read() == get_caller_address(), "Access denied: update_fee_recipient is only for the owner's use");
        assert!(new_fee_recipient != 0.try_into().unwrap(), "NEW_FEE_RECIPIENT_CANT_BE_ZERO");
        
        self.balancer_s.fee_recipient.write(new_fee_recipient);
        self.emit(FeeRecipientUpdate{new_fee_recipient});
    }

    #[external(v0)]
    fn update_base_token(ref self: ContractState, new_base_token:ContractAddress) {
        assert!(self.owner.read() == get_caller_address(), "Access denied: update_base_token is only for the owner's use");
        self.balancer_s.wrapped_native_token.write(new_base_token);
        self.router_s.native_base_token.write(new_base_token);
        self.emit(BaseTokenUpdate{new_base_token});
    }

    #[external(v0)]
    fn update_router_component_params(ref self: ContractState, new_delay:SlowModeDelay, min_amount_to_route:u256, new_punishment_bips:u16) {
        assert!(self.owner.read() == get_caller_address(), "Access denied: update_router_component_params is only for the owner's use");
        let max = self.max_slow_mode_delay.read();
        assert!(new_delay.block <= max.block && new_delay.ts <= max.ts, "Failed router params update: new_delay <= max_slow_mode_delay");
        self.router_s.delay.write(new_delay);
        self.router_s.min_to_route.write(min_amount_to_route);
        self.router_s.punishment_bips.write(new_punishment_bips);
        self.emit(RouterComponentUpdate{new_delay,min_amount_to_route,new_punishment_bips});
    }
    
    // apply methods performed by exchange invokers

    fn assert_whitelisted_invokers(self: @ContractState) {
        assert!(self.exchange_invokers.read(get_caller_address()), "Access denied: Only whitelisted invokers");
    }

    use kurosawa_akira::signature::V0OffchainMessage::{OffchainMessageHashImpl};
    use kurosawa_akira::signature::AkiraV0OffchainMessage::{OrderHashImpl,SNIP12MetadataImpl,IncreaseNonceHashImpl,WithdrawHashImpl};

    // methods for users to check if they build message hash correctly
    #[external(v0)]
    fn get_order_hash(self: @ContractState, order:Order) -> felt252 { order.get_message_hash(order.maker)}

    #[external(v0)]
    fn get_withdraw_hash(self: @ContractState, withdraw: Withdraw) -> felt252 { withdraw.get_message_hash(withdraw.maker)}
    #[external(v0)]
    fn get_increase_nonce_hash(self: @ContractState, increase_nonce:IncreaseNonce) -> felt252 { increase_nonce.get_message_hash(increase_nonce.maker)}


    #[external(v0)]
    fn apply_increase_nonce(ref self: ContractState, signed_nonce: SignedIncreaseNonce, gas_price:u256, cur_gas_per_action:u32) {
        assert_whitelisted_invokers(@self);
        self.nonce_s.apply_increase_nonce(signed_nonce, gas_price, cur_gas_per_action);
        self.balancer_s.latest_gas.write(gas_price);
    }


    #[external(v0)]
    fn apply_increase_nonces(ref self: ContractState, mut signed_nonces: Array<SignedIncreaseNonce>, gas_price:u256, cur_gas_per_action:u32) {
        assert_whitelisted_invokers(@self);
        loop {
            match signed_nonces.pop_front(){
                Option::Some(signed_nonce) => { self.nonce_s.apply_increase_nonce(signed_nonce, gas_price, cur_gas_per_action);},
                Option::None(_) => {break;}
            };
        };
        self.balancer_s.latest_gas.write(gas_price);
    }

    #[external(v0)]
    fn apply_withdraw(ref self: ContractState, signed_withdraw: SignedWithdraw, gas_price:u256, cur_gas_per_action:u32) {
        assert_whitelisted_invokers(@self);
        self.withdraw_s.apply_withdraw(signed_withdraw, gas_price, cur_gas_per_action);
        self.balancer_s.latest_gas.write(gas_price);
        self.withdraw_s.gas_steps.write(cur_gas_per_action);
    }

    #[external(v0)]
    fn apply_withdraws(ref self: ContractState, mut signed_withdraws: Array<SignedWithdraw>, gas_price:u256, cur_gas_per_action:u32) {
        assert_whitelisted_invokers(@self);
        loop {
            match signed_withdraws.pop_front(){
                Option::Some(signed_withdraw) => {self.withdraw_s.apply_withdraw(signed_withdraw, gas_price, cur_gas_per_action)},
                Option::None(_) => {break;}
            };
        };
        self.withdraw_s.gas_steps.write(cur_gas_per_action);
        self.balancer_s.latest_gas.write(gas_price);
    }

    #[external(v0)]
    fn apply_ecosystem_trades(ref self: ContractState, taker_orders:Array<(SignedOrder,bool)>, maker_orders: Array<SignedOrder>, iters:Array<(u16, bool)>, oracle_settled_qty:Array<u256>, gas_price:u256, cur_gas_per_action:u32) {
        assert_whitelisted_invokers(@self);
        self.ecosystem_trade_s.apply_ecosystem_trades(taker_orders, maker_orders, iters, oracle_settled_qty, gas_price, cur_gas_per_action);
        self.balancer_s.latest_gas.write(gas_price);
    }

    #[external(v0)]
    fn apply_single_execution_step(ref self: ContractState, taker_order:SignedOrder, maker_orders: Array<(SignedOrder,u256)>, total_amount_matched:u256, gas_price:u256, cur_gas_per_action:u32,as_taker_completed:bool, ) -> bool {
        assert_whitelisted_invokers(@self);
        let res = self.ecosystem_trade_s.apply_single_taker(taker_order, maker_orders, total_amount_matched, gas_price, cur_gas_per_action, as_taker_completed, false);
        self.balancer_s.latest_gas.write(gas_price);
        return res;
    }

    #[external(v0)]
    fn apply_execution_steps(ref self: ContractState,  mut bulk:Array<(SignedOrder, Array<(SignedOrder,u256)>, u256, bool)>,  gas_price:u256,  cur_gas_per_action:u32) -> Array<bool> {
        assert_whitelisted_invokers(@self);
        let mut res: Array<bool> = ArrayTrait::new();
            
        loop {
            match bulk.pop_front(){
                Option::Some((taker_order, maker_orders, total_amount_matched, as_taker_completed)) => {
                    res.append(self.ecosystem_trade_s.apply_single_taker(taker_order, maker_orders, total_amount_matched, gas_price, cur_gas_per_action, as_taker_completed, false));

                },
                Option::None(_) => {break;}
            };
        };
        self.balancer_s.latest_gas.write(gas_price);
        return res;
    }


    #[external(v0)]
    fn placeTakerOrder(ref self: ContractState, order: Order) {
        let tx_info = get_tx_info().unbox();

        assert(self.hash_lock.read() == 0, 'Lock already acquired');
        self.hash_lock.write(tx_info.transaction_hash);
        assert(order.maker == get_caller_address(), 'Maker must be caller');
        assert!(self.exchange_invokers.read(tx_info.account_contract_address), "Access denied: Only whitelisted invokers");
        self.scheduled_taker_order.write(order);
    }

    #[external(v0)]
    fn fullfillTakerOrder(ref self: ContractState, mut maker_orders:Array<(SignedOrder,u256)>,
                    total_amount_matched:u256, gas_steps:u32,gas_price:u256,  cur_gas_per_action:u32) {
        assert_whitelisted_invokers(@self);

        let tx_info = get_tx_info().unbox();
        assert(self.hash_lock.read() == tx_info.transaction_hash, 'Lock not acquired');
        self.ecosystem_trade_s.apply_single_taker(
            SignedOrder{order:self.scheduled_taker_order.read(), sign: array![].span(), router_sign:(0,0)},
            maker_orders, total_amount_matched, gas_price, gas_steps, true, true);
        // release lock
        self.hash_lock.write(0);
    }



    #[derive(Drop, Serde)]
    enum Step {
        BulkExecutionSteps: (Array<(SignedOrder, Array<(SignedOrder,u256)>, u256, bool)>, bool),
        SingleExecutionStep:((SignedOrder, Array<(SignedOrder,u256)>, u256, bool),bool),
        EcosystemTrades: (Array<(SignedOrder,bool)>, Array<SignedOrder>, Array<(u16, bool)>, Array<u256>),
        IncreaseNonceStep:SignedIncreaseNonce,
        WithdrawStep:SignedWithdraw,
    }


    #[external(v0)]
    fn apply_steps(ref self: ContractState, mut steps:Array<Step>, nonce_steps: u32, withdraw_steps:u32,router_steps:u32, ecosystem_steps:u32, gas_price:u256) {
        assert_whitelisted_invokers(@self);
        loop {
            match steps.pop_front(){
                Option::Some(step)=> {
                    match step {
                        Step::BulkExecutionSteps((data, is_ecosystem_gas_book)) => {
                            let gas_steps = if is_ecosystem_gas_book {ecosystem_steps} else {router_steps};
                            apply_execution_steps(ref self, data, gas_price, gas_steps);  
                        },    
                        Step::SingleExecutionStep((data, is_ecosystem_gas_book)) => {
                            let gas_steps = if is_ecosystem_gas_book {ecosystem_steps} else {router_steps};
                            let (taker_order, maker_orders, total_amount_matched,as_taker_completed) = data;
                            apply_single_execution_step(ref self, taker_order, maker_orders, total_amount_matched, gas_price, gas_steps, as_taker_completed);  
                        },
                        Step::EcosystemTrades((takers, makers, iters, oracle_settled_qty)) => {
                            apply_ecosystem_trades(ref self,takers,makers,iters,oracle_settled_qty, gas_price, ecosystem_steps);
                        },
                        Step::IncreaseNonceStep(data) => {apply_increase_nonce(ref self,data, gas_price, nonce_steps)},
                        Step::WithdrawStep(data) => {apply_withdraw(ref self,data, gas_price, withdraw_steps)},
                    };
                },
                Option::None(_) => {break;}
            };
        };
        self.balancer_s.latest_gas.write(gas_price);
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
        EcosystemTradeEvent: ecosystem_trade_component::Event,
        UpdateExchangeInvoker: UpdateExchangeInvoker,
        BaseTokenUpdate: BaseTokenUpdate,
        FeeRecipientUpdate: FeeRecipientUpdate,
        RouterComponentUpdate: RouterComponentUpdate,
        WithdrawComponentUpdate: WithdrawComponentUpdate,
        VersionUpdate: VersionUpdate
    }

    #[derive(Drop, starknet::Event)]
    struct UpdateExchangeInvoker {#[key] invoker: ContractAddress, enabled: bool}
    #[derive(Drop, starknet::Event)]
    struct BaseTokenUpdate {new_base_token: ContractAddress}
    #[derive(Drop, starknet::Event)]
    struct FeeRecipientUpdate {new_fee_recipient: ContractAddress}
    #[derive(Drop, starknet::Event)]
    struct RouterComponentUpdate {new_delay:SlowModeDelay, min_amount_to_route:u256, new_punishment_bips:u16}
    #[derive(Drop, starknet::Event)]
    struct WithdrawComponentUpdate {new_delay:SlowModeDelay}
    #[derive(Drop, starknet::Event)]
    struct VersionUpdate {new_version:u16}
    

}
