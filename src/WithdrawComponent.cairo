use starknet::ContractAddress;
use serde::Serde;
use kurosawa_akira::ExchangeBalance::NewGasFee;
use kurosawa_akira::utils::SlowModeLogic::SlowModeDelay;


#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
struct WithdrawNew {
    maker: ContractAddress,
    token: ContractAddress,
    amount: u256,
    salt: felt252,
    gas_fee: NewGasFee,
    reciever:ContractAddress
}

#[derive(Copy, Drop, Serde, PartialEq)]
struct SignedWithdrawNew {
    withdraw: WithdrawNew,
    sign: (felt252, felt252),
}

#[starknet::interface]
trait IWithdraw<TContractState> {
    // scheduels onchain withdraw so user can actually withdraw by apply_onchain_withdraw
    fn request_onchain_withdraw(ref self: TContractState, withdraw: WithdrawNew);
    // // cancels onchain withdraw_request so user prevent 
    // fn cancel_onchain_withdraw_request(ref self: TContractState, key:felt252);
    // can only be performed by the owner
    fn apply_onchain_withdraw(ref self: TContractState, key:felt252);
}


#[starknet::component]
mod withdraw_component {
    use kurosawa_akira::ExchangeBalance::exchange_balance_logic_component as balance_component;
    use balance_component::{InternalExchangeBalancebleImpl,ExchangeBalancebleImpl};
    use super::{WithdrawNew,SignedWithdrawNew,SlowModeDelay,IWithdraw,NewGasFee};
    use kurosawa_akira::SignerComponent::{ISignerLogic};
    use kurosawa_akira::utils::erc20::{IERC20DispatcherTrait, IERC20Dispatcher};
    use kurosawa_akira::ExchangeEntityStructures::Entities::FundsTraits::PoseidonHashImpl;
    use starknet::{get_caller_address,get_contract_address,get_block_timestamp,ContractAddress};
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
        #[key]
        token: ContractAddress,
        reciever:ContractAddress,
        amount: u256,
        salt: felt252,
        gas_fee: NewGasFee,
    }

    #[derive(Drop, starknet::Event)]
    struct Withdrawal {
        #[key]
        maker: ContractAddress,
        #[key]
        token: ContractAddress,
        reciever:ContractAddress,
        amount: u256,
    }

    #[storage]
    struct Storage {
        delay: SlowModeDelay, // set by exchange, can be updated but no more then original
        pending_reqs:LegacyMap::<felt252,(SlowModeDelay, WithdrawNew)>,
        gas_action:u256, //set by exchange
    }

    #[embeddable_as(Withdrawable)]
    impl WithdrawableImpl<TContractState, +HasComponent<TContractState>,+balance_component::HasComponent<TContractState>,+Drop<TContractState>,+ISignerLogic<TContractState>> of IWithdraw<ComponentState<TContractState>> {

        fn request_onchain_withdraw(ref self: ComponentState<TContractState>, withdraw: WithdrawNew) {
            assert(get_caller_address() == withdraw.maker, 'WRONG_MAKER');
            let key = withdraw.get_poseidon_hash();            
            let (pending_ts, w): (SlowModeDelay,WithdrawNew)  =  self.pending_reqs.read(key);
            assert(w == withdraw, 'ALREADY_REQUESTED');
            self.validate(w.maker, w.token, w.amount, w.gas_fee);
            self.pending_reqs.write(key, (SlowModeDelay {block:get_block_number(), ts: get_block_timestamp()}, withdraw));
            self.emit(ReqOnChainWithdraw{
                maker:withdraw.maker,token:withdraw.token,amount:withdraw.amount,salt:withdraw.salt,gas_fee:withdraw.gas_fee,
                        reciever:withdraw.reciever});
            
        }

        // fn cancel_onchain_withdraw_request(ref self: ComponentState<TContractState>, key:felt252) {
        //     let (delay, w_req): (SlowModeDelay, WithdrawNew) = self.pending_reqs.read(key);
        //     assert(get_caller_address() == w_req.maker, 'WRONG_MAKER');
        //     self.emit(ReqOnChainCancelled{maker:w_req.maker, withdraw_key:key});
        //     self.cleanup(w_req, delay, key);
        // }

        fn apply_onchain_withdraw(ref self: ComponentState<TContractState>, key:felt252) {
            let (delay, w_req): (SlowModeDelay,WithdrawNew) = self.pending_reqs.read(key);
            assert(get_caller_address() == w_req.maker, 'WRONG_MAKER');
            
            let limit:SlowModeDelay = self.delay.read();
            assert(get_block_number() - delay.block >= limit.block && get_block_timestamp() - delay.ts >= limit.ts, 'FEW_TIME_PASSED');
            let mut balancer = self.get_balancer_mut();
            balancer.burn(w_req.maker,w_req.amount,w_req.token);
            IERC20Dispatcher{ contract_address: w_req.token}.transfer(w_req.reciever, w_req.amount);
            self.emit(Withdrawal{maker:w_req.maker, token:w_req.token, amount:w_req.amount, reciever:w_req.reciever});
            self.cleanup(w_req, delay, key);
        }

    }

     #[generate_trait]
    impl InternalWithdrawableImpl<TContractState, +HasComponent<TContractState>,
    +balance_component::HasComponent<TContractState>,+Drop<TContractState>,+ISignerLogic<TContractState>> of InternalWithdrawable<TContractState> {
        fn initializer(ref self: ComponentState<TContractState>,delay:SlowModeDelay) {
            self.delay.write(delay);
        }
        // exposed only in contract user
        fn apply_withdraw(ref self: ComponentState<TContractState>, signed_withdraw: SignedWithdrawNew) {

            let hash = signed_withdraw.withdraw.get_poseidon_hash();
            let (delay, w_req):(SlowModeDelay,WithdrawNew) = self.pending_reqs.read(hash);
            if w_req != signed_withdraw.withdraw { // need to check sign cause offchain withdrawal
                let (r,s) = signed_withdraw.sign;
                assert(self.get_contract().check_sign(signed_withdraw.withdraw.maker,hash,r,s), 'WRONG_SIG');

            }
        
            let mut contract = self.get_balancer_mut();
            contract.burn(w_req.maker, w_req.amount, w_req.token);
            IERC20Dispatcher { contract_address: w_req.token }.transfer(w_req.maker, w_req.amount);
            self.emit(Withdrawal{maker:w_req.maker,token:w_req.token,amount:w_req.amount});

            // payment to exchange for gas
            let cur_gas = contract.get_latest_gas_price();
            contract.validate_and_apply_gas_fee_internal(w_req.maker,w_req.gas_fee, cur_gas);

            self.cleanup(w_req, delay, hash);
        }

        fn cleanup(ref self:ComponentState<TContractState>,mut w_req:WithdrawNew, delay:SlowModeDelay, key:felt252) {
            let zero_addr:ContractAddress = 0.try_into().unwrap();
            let mut contract = self.get_balancer_mut();

            contract.fee_recipient.write(zero_addr);//(w.maker, w.amount, w.token);

            w_req.amount = 0;
            w_req.token = zero_addr;
            w_req.maker = zero_addr;
            self.pending_reqs.write(key, (delay, w_req));
        }

        fn validate(self:@ComponentState<TContractState>,maker:ContractAddress,token:ContractAddress, amount:u256, gas_fee:NewGasFee) {
            let balancer =  self.get_balancer();
            let balance = balancer.balanceOf(maker,token);
            assert(!gas_fee.external_call && gas_fee.gas_per_action == self.gas_action.read() && gas_fee.fee_token == balancer.wrapped_native_token.read(), 'WRONG_GAS_FEE');
            let required_gas = balancer.get_latest_gas_price() * 2 * gas_fee.gas_per_action;  //require  reserve a bit more
            if gas_fee.fee_token == token {
                assert(balance >= required_gas + amount, 'FEW_BALANCE');
            } else {
                assert(balance >= amount , 'FEW_BALANCE');
                assert(balancer.balanceOf(maker,gas_fee.fee_token) >= required_gas, 'FEW_BALANCE_GAS');
            }
        }
        fn have_enough(self:@ComponentState<TContractState>,maker:ContractAddress,token:ContractAddress, amount:u256, gas_fee:NewGasFee) ->bool {
            let balancer =  self.get_balancer();
            let balance = balancer.balanceOf(maker,token);
            let required_gas = balancer.get_latest_gas_price() *  gas_fee.gas_per_action;
            if gas_fee.fee_token == token {
                return balance >= required_gas + amount;
            } else {
                return balance >= amount && balancer.balanceOf(maker, gas_fee.fee_token) >= required_gas;
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
