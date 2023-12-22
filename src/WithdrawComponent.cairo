use starknet::ContractAddress;
use serde::Serde;
use kurosawa_akira::Order::GasFee;
use kurosawa_akira::utils::SlowModeLogic::SlowModeDelay;


#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
struct Withdraw {
    maker: ContractAddress,
    token: ContractAddress,
    amount: u256,
    salt: felt252,
    gas_fee: GasFee,
    reciever:ContractAddress
}

#[derive(Copy, Drop, Serde, PartialEq)]
struct SignedWithdraw {
    withdraw: Withdraw,
    sign: (felt252, felt252),
}

#[starknet::interface]
trait IWithdraw<TContractState> {
    // scheduels onchain withdraw so user can actually withdraw by apply_onchain_withdraw
    fn request_onchain_withdraw(ref self: TContractState, withdraw: Withdraw);

    fn get_pending_withdraw(self:@TContractState, maker:ContractAddress, token:ContractAddress)->(SlowModeDelay,Withdraw);

    fn get_pending_withdraws(self:@TContractState,reqs:Array<(ContractAddress, ContractAddress)>)-> Array<(SlowModeDelay,Withdraw)>;
    
    // can only be performed by the owner
    fn apply_onchain_withdraw(ref self: TContractState, token:ContractAddress, key:felt252);

    fn get_withdraw_steps(self: @TContractState) -> u32;

    fn is_request_completed(self: @TContractState, w_hash:felt252) -> bool;
}


#[starknet::component]
mod withdraw_component {
    use kurosawa_akira::FundsTraits::{PoseidonHash,PoseidonHashImpl};
    use kurosawa_akira::ExchangeBalanceComponent::exchange_balance_logic_component as balance_component;
    use balance_component::{InternalExchangeBalancebleImpl,ExchangeBalancebleImpl};
    use super::{Withdraw,SignedWithdraw,SlowModeDelay,IWithdraw,GasFee};
    use kurosawa_akira::SignerComponent::{ISignerLogic};
    use kurosawa_akira::utils::erc20::{IERC20DispatcherTrait, IERC20Dispatcher};
    use starknet::{get_caller_address, get_contract_address, get_block_timestamp, ContractAddress};
    use starknet::info::get_block_number;


    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        ReqOnChainWithdraw: ReqOnChainWithdraw,
        Withdrawal: Withdrawal
    }

    #[derive(Drop, starknet::Event)]
    struct ReqOnChainWithdraw {
        #[key]
        maker: ContractAddress,
        token: ContractAddress,
        amount: u256,
        key:felt252
    }

    #[derive(Drop, starknet::Event)]
    struct Withdrawal {
        #[key]
        maker: ContractAddress,
        token: ContractAddress,
        reciever:ContractAddress,
        key:felt252,
        amount: u256,
    }

    #[storage]
    struct Storage {
        delay: SlowModeDelay, // set by exchange, can be updated but no more then original
        pending_reqs:LegacyMap::<(ContractAddress,ContractAddress),(SlowModeDelay, Withdraw)>,
        completed_reqs:LegacyMap::<felt252,bool>,
        gas_action:u32, //set by exchange
    }

    #[embeddable_as(Withdrawable)]
    impl WithdrawableImpl<TContractState, +HasComponent<TContractState>,+balance_component::HasComponent<TContractState>,+Drop<TContractState>,+ISignerLogic<TContractState>> of IWithdraw<ComponentState<TContractState>> {

        fn is_request_completed(self:@ComponentState<TContractState>, w_hash:felt252) -> bool { self.completed_reqs.read(w_hash)}


        fn get_pending_withdraw(self:@ComponentState<TContractState>,maker:ContractAddress, token:ContractAddress)->(SlowModeDelay, Withdraw) {
            return self.pending_reqs.read((token, maker));
        }

        fn get_pending_withdraws(self:@ComponentState<TContractState>, mut reqs:Array<(ContractAddress, ContractAddress)>) -> Array<(SlowModeDelay,Withdraw)> {
            let mut res: Array = ArrayTrait::new();            
            loop {
                match reqs.pop_front(){
                    Option::Some((maker,token)) => { res.append(self.pending_reqs.read((token, maker)));}, Option::None(_) => {break;}
                };
            };
            return res;
        }


        // get completed status

        fn request_onchain_withdraw(ref self: ComponentState<TContractState>, withdraw: Withdraw) {
            assert(get_caller_address() == withdraw.maker, 'WRONG_MAKER');
            assert(withdraw.amount > 0, 'WITHDRAW_CANT_BE_ZERO');
            let key = (withdraw.token, withdraw.maker);            
            let (pending_ts, w_prev): (SlowModeDelay, Withdraw)  = self.pending_reqs.read(key);
            let w_hash = withdraw.get_poseidon_hash();

            assert(w_prev != withdraw, 'ALREADY_REQUESTED');
            assert(w_prev.amount == 0 || self.completed_reqs.read(w_prev.get_poseidon_hash()), 'NOT_YET_COMPLETED_PREV');
           
            assert(!self.completed_reqs.read(w_hash),'ALREADY_COMPLETED');
            self.validate(withdraw.maker, withdraw.token, withdraw.amount, withdraw.gas_fee);
            
            self.pending_reqs.write(key, (SlowModeDelay {block:get_block_number(), ts: get_block_timestamp()}, withdraw));
            self.emit(ReqOnChainWithdraw{
                maker:withdraw.maker,token:withdraw.token,amount:withdraw.amount, key: w_hash});
            
        }

        fn get_withdraw_steps(self: @ComponentState<TContractState>) -> u32 { self.gas_action.read()}


        fn apply_onchain_withdraw(ref self: ComponentState<TContractState>, token:ContractAddress, key:felt252) {
            let caller = get_caller_address();
            let (delay, w_req): (SlowModeDelay,Withdraw) = self.pending_reqs.read((token, caller));
            assert(caller == w_req.maker, 'WRONG_MAKER');
            assert(key == w_req.get_poseidon_hash(),'WRONG_WITHDRAW');
            assert(!self.completed_reqs.read(key), 'ALREADY_COMPLETED');
            
            let limit:SlowModeDelay = self.delay.read();
            assert(get_block_number() - delay.block >= limit.block && get_block_timestamp() - delay.ts >= limit.ts, 'FEW_TIME_PASSED');
            
            let mut balancer = self.get_balancer_mut();
            balancer.burn(w_req.maker, w_req.amount, w_req.token);
            IERC20Dispatcher{ contract_address: w_req.token}.transfer(w_req.reciever, w_req.amount);
            self.emit(Withdrawal{maker:w_req.maker, token:w_req.token, amount:w_req.amount, key:key, reciever:w_req.reciever});
            
            self.completed_reqs.write(key, true);
        }

    }

     #[generate_trait]
    impl InternalWithdrawableImpl<TContractState, +HasComponent<TContractState>,
    +balance_component::HasComponent<TContractState>,+Drop<TContractState>,+ISignerLogic<TContractState>> of InternalWithdrawable<TContractState> {
        fn initializer(ref self: ComponentState<TContractState>,delay:SlowModeDelay, gas_action_cost:u32) {
            self.delay.write(delay);
            self.gas_action.write(gas_action_cost);
        }
        // exposed only in contract user
        fn apply_withdraw(ref self: ComponentState<TContractState>, signed_withdraw: SignedWithdraw, gas_price:u256) {
            let hash = signed_withdraw.withdraw.get_poseidon_hash();
            let (delay, w_req):(SlowModeDelay, Withdraw) = self.pending_reqs.read((signed_withdraw.withdraw.token, signed_withdraw.withdraw.maker));
            assert(!self.completed_reqs.read(hash), 'ALREADY_COMPLETED');
            
            if w_req != signed_withdraw.withdraw { // need to check sign cause offchain withdrawal
                let (r, s) = signed_withdraw.sign;
                assert(self.get_contract().check_sign(signed_withdraw.withdraw.maker, hash, r, s), 'WRONG_SIGN');
            }
            let w_req = signed_withdraw.withdraw;
        
            let mut contract = self.get_balancer_mut();

             // payment to exchange for gas
            let gas_fee_amount = contract.validate_and_apply_gas_fee_internal(w_req.maker, w_req.gas_fee, gas_price, 1);
            let tfer_amount = if w_req.token == w_req.gas_fee.fee_token {w_req.amount - gas_fee_amount } else {  w_req.amount};

            contract.burn(w_req.maker, tfer_amount, w_req.token);
            IERC20Dispatcher { contract_address: w_req.token }.transfer(w_req.maker, tfer_amount);
            self.emit(Withdrawal{maker:w_req.maker, token:w_req.token, amount: w_req.amount, key:hash, reciever:w_req.reciever});

           self.completed_reqs.write(hash, true);
        }


        fn validate(self:@ComponentState<TContractState>,maker:ContractAddress,token:ContractAddress, amount:u256, gas_fee:GasFee) {
            let balancer =  self.get_balancer();
            let balance = balancer.balanceOf(maker, token);
            assert(gas_fee.gas_per_action == self.gas_action.read(), 'WRONG_GAS_PER_ACTION');
            assert(gas_fee.fee_token == balancer.wrapped_native_token.read(), 'WRONG_GAS_FEE_TOKEN');
            let required_gas = balancer.get_latest_gas_price() * 2 * gas_fee.gas_per_action.into();  //require  reserve a bit more
            assert(balance >= amount , 'FEW_BALANCE');
            if gas_fee.fee_token == token {
                assert(amount >= required_gas, 'GAS_MORE_THAN_REQUESTED');

            } else {
                assert(balancer.balanceOf(maker, gas_fee.fee_token) >= required_gas, 'FEW_BALANCE_GAS');
            }
        }
    }   


    // this (or something similar) will potentially be generated in the next RC
    #[generate_trait]
    impl GetBalancer<
        TContractState,
        +HasComponent<TContractState>,
        +balance_component::HasComponent<TContractState>,
        +Drop<TContractState>> of GetBalancerTrait<TContractState> {
        fn get_balancer(
            self: @ComponentState<TContractState>
        ) -> @balance_component::ComponentState<TContractState> {
            let contract = self.get_contract();
            balance_component::HasComponent::<TContractState>::get_component(contract)
        }

        fn get_balancer_mut(
            ref self: ComponentState<TContractState>
        ) -> balance_component::ComponentState<TContractState> {
            let mut contract = self.get_contract_mut();
            balance_component::HasComponent::<TContractState>::get_component_mut(ref contract)
        }
    }
}
