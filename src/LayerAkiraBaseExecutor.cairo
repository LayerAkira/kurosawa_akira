
use kurosawa_akira::NonceComponent::{SignedIncreaseNonce, IncreaseNonce};
use kurosawa_akira::Order::{SignedOrder, Order, OrderTradeInfo,GasContext};
use kurosawa_akira::WithdrawComponent::{SignedWithdraw, Withdraw};
use starknet::{ContractAddress};


#[starknet::interface]
trait ILayerAkiraBaseExecutor<TContractState> {
    fn get_order_hash(self: @TContractState, order:Order) -> felt252;
    
    fn apply_increase_nonces(ref self: TContractState, signed_nonces: Array<SignedIncreaseNonce>, gas_price:u256);

    fn apply_increase_nonce(ref self: TContractState, signed_nonce: SignedIncreaseNonce, gas_price:u256, cur_gas_per_action:u32);

    fn apply_withdraw(ref self: TContractState, signed_withdraw: SignedWithdraw, gas_price:u256, cur_gas_per_action:u32);

    fn apply_withdraws(ref self: TContractState, signed_withdraws: Array<SignedWithdraw>, gas_price:u256, cur_gas_per_action:u32);

    fn apply_ecosystem_trades(ref self: TContractState, taker_orders:Array<(SignedOrder,bool)>, maker_orders: Array<SignedOrder>, iters:Array<(u16,bool)>, oracle_settled_qty:Array<u256>, gas_price:u256, cur_gas_per_action:u32);
    
    fn apply_single_execution_step(ref self: TContractState, taker_order:SignedOrder, maker_orders: Array<(SignedOrder,u256)>, total_amount_matched:u256,  gas_price:u256, cur_gas_per_action:u32, as_taker_completed:bool) -> bool;
    
    fn apply_execution_steps(ref self: TContractState, bulk:Array<(SignedOrder, Array<(SignedOrder,u256)>, u256, bool)>,  gas_price:u256, cur_gas_per_action:u32) -> Array<bool>;

    fn apply_single_taker(ref self: TContractState, signed_taker_order:SignedOrder, signed_maker_orders:Span<(SignedOrder,u256)>,
                    total_amount_matched:u256, gas_price:u256,  cur_gas_per_action:u32, as_taker_completed:bool, 
                    skip_taker_validation:bool, gas_trades_to_pay:u16, transfer_taker_recieve_back:bool, allow_charge_gas_on_receipt:bool)  -> (bool, felt252);
    fn get_order_info(self: @TContractState, order_hash: felt252) -> OrderTradeInfo;
    
    fn apply_trades(ref self:TContractState, 
                                taker_order:Order, signed_maker_orders:Span<(SignedOrder,u256)>,
                                taker_hash:felt252,
                                as_taker_completed:bool) -> (u256, u256);
    fn apply_punishment(ref self:TContractState, taker_order:Order, signed_maker_orders:Span<(SignedOrder,u256)>, 
                                taker_hash:felt252, as_taker_completed:bool, gas_ctx:GasContext) ;
    fn finalize_router_taker(ref self:TContractState, taker_order:Order, taker_hash:felt252, received_amount:u256, unspent_amount:u256, trades:u16,
                    spent_amount:u256, transfer_back_received:bool, tfer_back_unspent:bool, gas_ctx:GasContext);
    fn is_wlsted_invoker(self:@TContractState, caller:ContractAddress)->bool;
}

#[starknet::contract]
mod LayerAkiraBaseExecutor {
    use kurosawa_akira::BaseTradeComponent::base_trade_component as  base_trade_component;
    use starknet::{ContractAddress, get_caller_address, get_tx_info};

    use base_trade_component::InternalBaseOrderTradable;
    use base_trade_component::{TakerMatchContext};
    use kurosawa_akira::LayerAkiraCore::{ILayerAkiraCoreDispatcherTrait, ILayerAkiraCoreDispatcher};

    use kurosawa_akira::utils::SlowModeLogic::SlowModeDelay;
    use kurosawa_akira::WithdrawComponent::{SignedWithdraw, Withdraw};
    use kurosawa_akira::NonceComponent::{SignedIncreaseNonce, IncreaseNonce};
    use kurosawa_akira::signature::V0OffchainMessage::{OffchainMessageHashImpl};
    use kurosawa_akira::signature::AkiraV0OffchainMessage::{OrderHashImpl,SNIP12MetadataImpl,IncreaseNonceHashImpl,WithdrawHashImpl};
    use kurosawa_akira::Order::{SignedOrder, Order, SimpleOrder,GasContext};
    use kurosawa_akira::AccessorComponent::accessor_logic_component as accessor_logic_component;
    use accessor_logic_component::InternalAccesorable;
    
    
    component!(path: base_trade_component,storage: base_trade_s, event:BaseTradeEvent);
    component!(path: accessor_logic_component, storage: accessor_s, event:AccessorEvent);
    

    #[abi(embed_v0)]
    impl BaseOrderTradableImpl = base_trade_component::BaseTradable<ContractState>;
    #[abi(embed_v0)]
    impl AccsesorableImpl = accessor_logic_component::Accesorable<ContractState>;
    
    #[storage]
    struct Storage {
        #[substorage(v0)]
        base_trade_s: base_trade_component::Storage,
        #[substorage(v0)]
        accessor_s: accessor_logic_component::Storage,    
        exchange_invokers: starknet::storage::Map::<ContractAddress, bool>,
    }


    #[constructor]
    fn constructor(ref self: ContractState, core_address:ContractAddress, router_address:ContractAddress, owner:ContractAddress) {
        self.base_trade_s.core_contract.write(core_address);
        self.base_trade_s.router_contract.write(router_address);
        self.exchange_invokers.write(ILayerAkiraCoreDispatcher {contract_address:core_address }.get_owner(), true);
        self.accessor_s.owner.write(owner);
        self.accessor_s.global_executor_epoch.write(1);
    }

    #[external(v0)]
    fn get_core(self: @ContractState) -> ContractAddress {self.base_trade_s.core_contract.read()}
    #[external(v0)]
    fn get_router(self: @ContractState) -> ContractAddress {self.base_trade_s.router_contract.read()}
    #[external(v0)]
    fn is_wlsted_invoker(self:@ContractState, caller:ContractAddress)->bool {self.exchange_invokers.read(caller)}

    #[external(v0)]
    fn update_exchange_invokers(ref self: ContractState, invoker:ContractAddress, enabled:bool) {
        self.accessor_s.only_owner();
        self.exchange_invokers.write(invoker, enabled);
        self.emit(UpdateExchangeInvoker{invoker, enabled});
    }


    #[external(v0)]
    fn get_order_hash(self: @ContractState, order:Order) -> felt252 { order.get_message_hash(order.maker)}

    #[external(v0)]
    fn apply_increase_nonce(ref self: ContractState, signed_nonce: SignedIncreaseNonce, gas_price:u256, cur_gas_per_action:u32) {
        assert_whitelisted_invokers(@self, get_caller_address());
        ILayerAkiraCoreDispatcher {contract_address:self.base_trade_s.core_contract.read()}
            .apply_increase_nonce(signed_nonce, gas_price, cur_gas_per_action);
    }


    #[external(v0)]
    fn apply_increase_nonces(ref self: ContractState, mut signed_nonces: Array<SignedIncreaseNonce>, gas_price:u256, cur_gas_per_action:u32) {
        assert_whitelisted_invokers(@self, get_caller_address());
        ILayerAkiraCoreDispatcher {contract_address:self.base_trade_s.core_contract.read()}
            .apply_increase_nonces(signed_nonces,gas_price,cur_gas_per_action);
    }

    #[external(v0)]
    fn apply_withdraw(ref self: ContractState, signed_withdraw: SignedWithdraw, gas_price:u256, cur_gas_per_action:u32) {
        assert_whitelisted_invokers(@self, get_caller_address());
        ILayerAkiraCoreDispatcher {contract_address:self.base_trade_s.core_contract.read()}.
            apply_withdraw(signed_withdraw, gas_price, cur_gas_per_action);
    }

    #[external(v0)]
    fn apply_withdraws(ref self: ContractState, mut signed_withdraws: Array<SignedWithdraw>, gas_price:u256, cur_gas_per_action:u32) {
        assert_whitelisted_invokers(@self, get_caller_address());
        ILayerAkiraCoreDispatcher {contract_address:self.base_trade_s.core_contract.read()}.
            apply_withdraws(signed_withdraws, gas_price, cur_gas_per_action);
    }

    #[external(v0)]
    fn apply_ecosystem_trades(ref self: ContractState, taker_orders:Array<(SignedOrder,bool)>, maker_orders: Array<SignedOrder>, iters:Array<(u16, bool)>, oracle_settled_qty:Array<u256>, gas_price:u256, cur_gas_per_action:u32) {
        assert_whitelisted_invokers(@self, get_caller_address());
        self.base_trade_s.apply_ecosystem_trades(taker_orders, maker_orders, iters, oracle_settled_qty,  GasContext{gas_price, cur_gas_per_action});
    }

    #[external(v0)]
    fn apply_single_execution_step(ref self: ContractState, taker_order:SignedOrder, maker_orders: Array<(SignedOrder,u256)>, total_amount_matched:u256, gas_price:u256, cur_gas_per_action:u32,as_taker_completed:bool, ) -> bool {
        assert_whitelisted_invokers(@self, get_caller_address());
        let taker_ctx = TakerMatchContext{as_taker_completed, skip_taker_validation:false, gas_trades_to_pay:maker_orders.len().try_into().unwrap(), transfer_taker_recieve_back:taker_order.order.flags.external_funds, allow_charge_gas_on_receipt:true};
        let (succ, _) =  self.base_trade_s.apply_single_taker(taker_order, maker_orders.span(), total_amount_matched, taker_ctx, GasContext{gas_price, cur_gas_per_action});
        
        
        return succ;
    }

    #[external(v0)]
    fn apply_execution_steps(ref self: ContractState,  mut bulk:Array<(SignedOrder, Array<(SignedOrder,u256)>, u256, bool)>,  gas_price:u256,  cur_gas_per_action:u32) -> Array<bool> {
        assert_whitelisted_invokers(@self, get_caller_address());
        let mut res: Array<bool> = ArrayTrait::new();
        
        loop {
            match bulk.pop_front(){
                Option::Some((taker_order, maker_orders, total_amount_matched, as_taker_completed)) => {
                    let taker_ctx = TakerMatchContext{as_taker_completed, skip_taker_validation:false, gas_trades_to_pay:maker_orders.len().try_into().unwrap(), transfer_taker_recieve_back:taker_order.order.flags.external_funds, allow_charge_gas_on_receipt:true};
                    let (succ, _) = self.base_trade_s.apply_single_taker(taker_order, maker_orders.span(), total_amount_matched, taker_ctx, GasContext{gas_price, cur_gas_per_action});
                    res.append(succ);

                },
                Option::None(_) => {break;}
            };
        };
        return res;
    }

    #[external(v0)]
    fn apply_single_taker(ref self: ContractState, signed_taker_order:SignedOrder, mut signed_maker_orders:Span<(SignedOrder,u256)>,
                    total_amount_matched:u256, gas_price:u256,  cur_gas_per_action:u32, as_taker_completed:bool, 
                    skip_taker_validation:bool, gas_trades_to_pay:u16, transfer_taker_recieve_back:bool, allow_charge_gas_on_receipt:bool)  -> (bool, felt252) {
        self.accessor_s.only_authorized_by_user(signed_taker_order.order.maker, get_caller_address());
        // no need to check for mm approvals since flags affected flow of the taker
        let taker_ctx = TakerMatchContext{as_taker_completed, skip_taker_validation, gas_trades_to_pay, transfer_taker_recieve_back, allow_charge_gas_on_receipt};
        self.base_trade_s.apply_single_taker(signed_taker_order, signed_maker_orders, total_amount_matched, taker_ctx, GasContext{gas_price, cur_gas_per_action}
        )
    }

    #[external(v0)]
    fn apply_trades(ref self:ContractState, taker_order:Order, mut signed_maker_orders:Span<(SignedOrder,u256)>,
                                taker_hash:felt252, as_taker_completed:bool) -> (u256, u256) {
        self.accessor_s.only_authorized_by_user(taker_order.maker, get_caller_address());
        self.base_trade_s.apply_trades(taker_order, signed_maker_orders, taker_hash, as_taker_completed)    
    }
    #[external(v0)]
    fn finalize_router_taker(ref self:ContractState, taker_order:Order, taker_hash:felt252, received_amount:u256, unspent_amount:u256, trades:u16, spent_amount:u256, 
                    transfer_back_received:bool, tfer_back_unspent:bool, gas_ctx:GasContext) {
        self.accessor_s.only_authorized_by_user(taker_order.maker, get_caller_address());
        self.base_trade_s.finalize_router_taker(taker_order,taker_hash,received_amount, unspent_amount, trades, spent_amount, transfer_back_received,tfer_back_unspent, gas_ctx)
    }
    #[external(v0)]
    fn apply_punishment(ref self:ContractState, taker_order:Order, mut signed_maker_orders:Span<(SignedOrder,u256)>, 
                                taker_hash:felt252, as_taker_completed:bool,gas_ctx:GasContext) {
        self.accessor_s.only_authorized_by_user(taker_order.maker, get_caller_address());
        //mb also autorized by router?
        self.base_trade_s.apply_punishment(taker_order, signed_maker_orders, taker_hash, as_taker_completed, gas_ctx);
    
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
        assert_whitelisted_invokers(@self, get_caller_address());
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
    }

    fn assert_whitelisted_invokers(self: @ContractState, caller:ContractAddress) {
        assert!(self.exchange_invokers.read(caller), "Access denied: Only whitelisted invokers");
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        BaseTradeEvent: base_trade_component::Event,
        UpdateExchangeInvoker: UpdateExchangeInvoker,
        AccessorEvent: accessor_logic_component::Event,
    }

    #[derive(Drop, starknet::Event)]
    struct UpdateExchangeInvoker {#[key] invoker: ContractAddress, enabled: bool}
}

