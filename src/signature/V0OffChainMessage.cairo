
use core::option::OptionTrait;
use core::traits::TryInto;
use box::BoxTrait;
use starknet::{ contract_address_const, get_tx_info, get_caller_address, testing::set_caller_address,ContractAddress};
use pedersen::PedersenTrait;
use hash::{HashStateTrait, HashStateExTrait};
use super::IOffchainMessage;

// const STARKNET_DOMAIN_TYPE_HASH: felt252 = selector!("StarkNetDomain(name:felt,version:felt,chainId:felt)");
const STARKNET_DOMAIN_TYPE_HASH: felt252 = 0x1BFC207425A47A5DFA1A50A4F5241203F50624CA5FDF5E18755765416B8E288;
// const U256_TYPE_HASH: felt252 = selector!("u256(low:felt,high:felt)");
const U256_TYPE_HASH:felt252 = 0x2EE86241508F9CA7043FB572033E45C445012A8DBB2B929391D37FC44FBFCEB;


#[derive(Drop, Copy, Hash)]
struct StarknetDomain {
    name: felt252,
    version: felt252,
    chain_id: felt252,
}

impl OffchainMessageHashImpl<T, +IOffchainMessage::IStructHash<T>, impl metadata: IOffchainMessage::SNIP12Metadata> of IOffchainMessage::IOffchainMessageHash<T> {
    fn get_message_hash(self: @T, delegator:ContractAddress) -> felt252 {
        let domain = StarknetDomain {
            name: metadata::name(), version: metadata::version(), chain_id: get_tx_info().unbox().chain_id
        };
        let mut state = PedersenTrait::new(0);
        state = state.update_with('StarkNet Message');
        state = state.update_with(domain.hash_struct());
        state = state.update_with(delegator);
        state = state.update_with(self.hash_struct());
        // Hashing with the amount of elements being hashed 
        state = state.update_with(4);
        state.finalize()
    }
}

impl StructHashStarknetDomainImpl of IOffchainMessage::IStructHash<StarknetDomain> {
    fn hash_struct(self: @StarknetDomain) -> felt252 {
        let mut state = PedersenTrait::new(0);
        state = state.update_with(STARKNET_DOMAIN_TYPE_HASH);
        state = state.update_with(*self);
        state = state.update_with(4);
        state.finalize()
    }
}

impl StructHashU256Impl of IOffchainMessage::IStructHash<u256> {
    fn hash_struct(self: @u256) -> felt252 {
        let mut state = PedersenTrait::new(0);
        state = state.update_with(U256_TYPE_HASH);
        state = state.update_with(*self);
        state = state.update_with(3);
        state.finalize()
    }
}