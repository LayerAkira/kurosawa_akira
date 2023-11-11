use serde::Serde;
use starknet::ContractAddress;
use starknet::contract_address_to_felt252;
use array::ArrayTrait;

use kurosawa_akira::V2_pools::RouterWrapper::RouterWrapper;
use kurosawa_akira::V2_pools::RouterWrapper::SwapExactInfo;

#[starknet::contract]
mod DummyWrapper {
    use super::SwapExactInfo;

    use starknet::ContractAddress;
    use starknet::contract_address_to_felt252;

    #[constructor]
    fn constructor(ref self: ContractState) {}

    #[storage]
    struct Storage {}

    #[external(v0)]
    impl DummyWrapperInpl of super::RouterWrapper<ContractState> {
        fn swap(ref self: ContractState, swap_info: SwapExactInfo, recipient: ContractAddress) {}

        fn get_amount_out(self: @ContractState, swap_info: SwapExactInfo) -> u256 {
            return 42;
        }
    }
}

use super::RouterWrapper::AbstractV2Dispatcher;
use super::RouterWrapper::AbstractV2DispatcherTrait;
use super::RouterWrapper::RouterWrapperDispatcher;
use super::RouterWrapper::RouterWrapperDispatcherTrait;

// #[cfg(test)]
// mod tests {
//     use core::option::OptionTrait;
//     use core::traits::TryInto;
//     use core::result::ResultTrait;
//     use snforge_std::declare;
//     use starknet::ContractAddress;
//     use snforge_std::ContractClassTrait;
//     use super::RouterWrapperDispatcher;
//     use super::RouterWrapperDispatcherTrait;

//     use super::AbstractV2Dispatcher;
//     use super::AbstractV2DispatcherTrait;
//     use super::SwapExactInfo;

//     use debug::PrintTrait;

//     use starknet::info::get_block_number;

//     fn another_function(swap: SwapExactInfo) {
//         // 'Another function.'.print();
//         // get_block_number().print()
//     }

//     #[test]
//     #[available_gas(10000000000)]
//     #[fork("forked")]
//     fn add_two_and_two() {
//         let contract = declare('ConcreteV2');
//         let contract_address = contract.deploy(@ArrayTrait::new()).unwrap();

//         // Create a Dispatcher object that will allow interacting with the deployed contract
//         let dispatcher = AbstractV2Dispatcher { contract_address: contract_address };
//         let zero_address: ContractAddress = starknet::contract_address_try_from_felt252(0).unwrap();

//         let dummy_wrapper_cls = declare('DummyWrapper');
//         let dummy_wrapper_contract = dummy_wrapper_cls.deploy(@ArrayTrait::new()).unwrap();
//         let dummy_wrapper = RouterWrapperDispatcher { contract_address: dummy_wrapper_contract };

//         let s = SwapExactInfo {
//             amount_in_pool: 0,
//             amount_out_min: 0,
//             token_in: contract_address,
//             token_out: contract_address,
//             pool: contract_address,
//         };
//         dispatcher.add_router(dummy_wrapper_contract);
//         another_function(s);

//         // dummy_wrapper.swap(0, 0, zero_address, zero_address, zero_address, zero_address);
//         // let result = dispatcher.get_amount_out(0,zero_address,zero_address,zero_address,2);
//         // let res = dummy_wrapper.get_amount_out(0, zero_address, zero_address, zero_address);
//         assert(dispatcher.get_amount_out(s, 1) == 42, 'result is not 42');
//     }
// }
