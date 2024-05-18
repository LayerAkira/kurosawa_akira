
use core::option::OptionTrait;
use core::traits::TryInto;
use box::BoxTrait;
use starknet::{ contract_address_const, get_tx_info, get_caller_address, testing::set_caller_address,ContractAddress};
use hash::{HashStateTrait, HashStateExTrait};


trait IStructHash<T> {
    fn hash_struct(self: @T) -> felt252;
}

trait IOffchainMessageHash<T> {
    fn get_message_hash(self: @T, delegator:ContractAddress) -> felt252;
}

trait SNIP12Metadata {
    fn name() -> felt252;    /// Returns the name of the dapp.
    fn version() -> felt252;  /// Returns the version of the dapp.
}
