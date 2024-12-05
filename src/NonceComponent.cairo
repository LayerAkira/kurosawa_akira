use kurosawa_akira::Order::GasFee;
use starknet::ContractAddress;

use pedersen::PedersenTrait;
use hash::{HashStateTrait, HashStateExTrait};

use kurosawa_akira::signature::V0OffchainMessage::{OffchainMessageHashImpl};
use kurosawa_akira::signature::AkiraV0OffchainMessage::{IncreaseNonceHashImpl, SNIP12MetadataImpl};


#[derive(Copy, Drop, Serde, PartialEq, Hash)]
struct IncreaseNonce {
    maker: ContractAddress,
    new_nonce: u32,
    gas_fee: GasFee,
    salt: felt252,
    sign_scheme:felt252
}


#[derive(Copy, Drop, Serde)]
struct SignedIncreaseNonce {
    increase_nonce: IncreaseNonce,
    sign: Span<felt252>,
}

#[starknet::interface]
trait INonceLogic<TContractState> {
    fn get_nonce(self: @TContractState, maker: ContractAddress) -> u32;
    fn get_nonces(self: @TContractState, makers: Span<ContractAddress>)-> Array<u32>;
}



#[starknet::component]
mod nonce_component {
    use kurosawa_akira::signature::IOffchainMessage::IOffchainMessageHash;
    use kurosawa_akira::ExchangeBalanceComponent::INewExchangeBalance;
    use kurosawa_akira::ExchangeBalanceComponent::exchange_balance_logic_component as balance_component;
    use balance_component::{InternalExchangeBalancebleImpl,ExchangeBalancebleImpl};
    use super::{GasFee,ContractAddress};
    use kurosawa_akira::SignerComponent::{ISignerLogic};
    
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
        nonces: starknet::storage::Map::<ContractAddress, u32>, // user address to his trading nonce
    }

    #[embeddable_as(Nonceable)]
    impl NonceableImpl<TContractState, +HasComponent<TContractState>,
    +balance_component::HasComponent<TContractState>,+Drop<TContractState>,+ISignerLogic<TContractState>> of super::INonceLogic<ComponentState<TContractState>> {

        
        fn get_nonce(self: @ComponentState<TContractState>, maker: ContractAddress) -> u32 { self.nonces.read(maker)}

        fn get_nonces(self: @ComponentState<TContractState>, makers: Span<ContractAddress>) -> Array<u32> {
            //Note makers should not be zero
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
        fn apply_increase_nonce(ref self: ComponentState<TContractState>, signed_nonce_increase: super::SignedIncreaseNonce, gas_price:u256, cur_gas_per_action:u32) {
            let nonce_increase = signed_nonce_increase.increase_nonce;
            let key = nonce_increase.get_message_hash(nonce_increase.maker);
            assert!(self.get_contract().check_sign(nonce_increase.maker, key, signed_nonce_increase.sign, nonce_increase.sign_scheme), "Failed maker signature check (key, r, s) = ({})", key);
            assert!(nonce_increase.new_nonce > self.nonces.read(nonce_increase.maker), "Wrong nonce (Failed new_nonce ({}) > prev_nonce ({}))", nonce_increase.new_nonce, self.nonces.read(nonce_increase.maker));
            
            let mut balancer = self.get_balancer_mut();
            balancer.validate_and_apply_gas_fee_internal(nonce_increase.maker, nonce_increase.gas_fee, gas_price, 1, cur_gas_per_action, balancer.get_wrapped_native_token());
            self.nonces.write(nonce_increase.maker, nonce_increase.new_nonce);

            self.emit(NonceIncrease{ maker: nonce_increase.maker, new_nonce:nonce_increase.new_nonce});
        }
        fn update_nonce(ref self: ComponentState<TContractState>, maker:ContractAddress, new_nonce:u32 ) {
            assert!(new_nonce > self.nonces.read(maker), "Wrong nonce (Failed new_nonce ({}) > prev_nonce ({}))", new_nonce, self.nonces.read(maker));
            self.emit(NonceIncrease{ maker: maker, new_nonce:new_nonce});
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