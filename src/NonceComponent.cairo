use kurosawa_akira::Order::GasFee;
use starknet::ContractAddress;

#[derive(Copy, Drop, Serde, PartialEq)]
struct IncreaseNonce {
    maker: ContractAddress,
    new_nonce: u32,
    gas_fee: GasFee,
    salt: felt252,
}

#[derive(Copy, Drop, Serde)]
struct SignedIncreaseNonce {
    increase_nonce: IncreaseNonce,
    sign: (felt252, felt252),
}

#[starknet::interface]
trait INonceLogic<TContractState> {
    // fn apply_increase_nonce(ref self: TContractState, signed_nonce_increase: SignedIncreaseNonce);
    fn get_nonce(self: @TContractState, maker: ContractAddress) -> u32;
    fn get_nonces(self: @TContractState, makers: Span<ContractAddress>)-> Array<u32>;
}



#[starknet::component]
mod nonce_component {
    use kurosawa_akira::ExchangeBalanceComponent::INewExchangeBalance;
    use kurosawa_akira::ExchangeBalanceComponent::exchange_balance_logic_component as balance_component;
    use balance_component::{InternalExchangeBalancebleImpl,ExchangeBalancebleImpl};
    use super::{GasFee,ContractAddress};
    use kurosawa_akira::SignerComponent::{ISignerLogic};
    use kurosawa_akira::FundsTraits::PoseidonHashImpl;

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        NonceIncrease: NonceIncrease,
    }

    #[derive(Drop, starknet::Event)]
    struct NonceIncrease {
        #[key]
        maker: ContractAddress,
        new_nonce: u32,
    }

    #[storage]
    struct Storage {
        nonces: LegacyMap::<ContractAddress, u32>,
    }

    #[embeddable_as(Nonceable)]
    impl NonceableImpl<TContractState, +HasComponent<TContractState>,
    +balance_component::HasComponent<TContractState>,+Drop<TContractState>,+ISignerLogic<TContractState>> of super::INonceLogic<ComponentState<TContractState>> {

        
        fn get_nonce(self: @ComponentState<TContractState>, maker: ContractAddress) -> u32 {
            self.nonces.read(maker)
        }

        fn get_nonces(self: @ComponentState<TContractState>, makers: Span<ContractAddress>) -> Array<u32> {
            let mut res: Array<u32> = ArrayTrait::new();
            let mut idx = 0;
            let sz = makers.len(); 
            loop {
                let item = *makers.at(idx);
                res.append(self.nonces.read(item));
                idx += 1;
                if idx == sz { break;}
            };
            return res;
        }
    }

     #[generate_trait]
    impl InternalWithdrawableImpl<TContractState, +HasComponent<TContractState>,
    +balance_component::HasComponent<TContractState>,+Drop<TContractState>,+ISignerLogic<TContractState>> of InternalNonceable<TContractState> {
        fn apply_increase_nonce(ref self: ComponentState<TContractState>, signed_nonce_increase: super::SignedIncreaseNonce) {
            let nonce_increase = signed_nonce_increase.increase_nonce;
            let key = nonce_increase.get_poseidon_hash();
            let (r,s) = signed_nonce_increase.sign;
            assert(self.get_contract().check_sign(nonce_increase.maker,key,r,s),'WRONG_SIG');
            assert(nonce_increase.new_nonce > self.nonces.read(nonce_increase.maker), 'WRONG_NONCE');
            
            let mut balancer = self.get_balancer_mut();
            balancer.validate_and_apply_gas_fee_internal(nonce_increase.maker, nonce_increase.gas_fee, balancer.get_latest_gas_price(), 1);
            self.nonces.write(nonce_increase.maker, nonce_increase.new_nonce);

            self.emit(NonceIncrease{ maker: nonce_increase.maker,new_nonce:nonce_increase.new_nonce});
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