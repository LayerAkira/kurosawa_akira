use serde::Serde;
use starknet::ContractAddress;
use starknet::contract_address_to_felt252;
use array::ArrayTrait;

#[derive(Copy, Drop, Serde)]
struct SwapExactInfo {
    amount_in_pool: u256,
    amount_out_min: u256,
    token_in: ContractAddress,
    token_out: ContractAddress,
    pool: ContractAddress
}


#[starknet::interface]
trait RouterWrapper<T> {
    fn swap(ref self: T, swap_info: SwapExactInfo, recipient: ContractAddress);

    fn get_amount_out(self: @T, swap_info: SwapExactInfo) -> u256;
}

// #[starknet::contract]
// mod DummyWrapper {
//     use super::SwapExactInfo;

//     use starknet::ContractAddress;
//     use starknet::contract_address_to_felt252;

//         #[constructor]
//     fn constructor(ref self: ContractState) {
//     }

//     #[storage]
//     struct Storage {}

//     #[external(v0)]
//     impl DummyWrapperInpl of super::RouterWrapper<ContractState> {
//         fn swap(ref self: ContractState, swap_info: SwapExactInfo, recipient: ContractAddress) {}

//         fn get_amount_out(self: @ContractState, swap_info: SwapExactInfo,) -> u256 {
//             return 42;
//         }
//     }
// }

#[starknet::interface]
trait AbstractV2<T> {
    fn swap(ref self: T, swap_info: SwapExactInfo, recipient: ContractAddress, market_id: u16);

    fn get_amount_out(self: @T, swap_info: SwapExactInfo, market_id: u16) -> u256;

    fn add_router(ref self: T, router: ContractAddress);
}


#[starknet::contract]
mod ConcreteV2 {
    use starknet::ContractAddress;
    use starknet::contract_address_to_felt252;
    use super::RouterWrapperDispatcher;
    use super::RouterWrapperDispatcherTrait;
    use kurosawa_akira::utils::erc20::IERC20DispatcherTrait;
    use kurosawa_akira::utils::erc20::IERC20Dispatcher;
    use starknet::get_caller_address;
    use starknet::get_contract_address;


    #[storage]
    struct Storage {
        market_to_wrapper: LegacyMap::<u16, ContractAddress>,
        _idx: u16
    }
    use super::SwapExactInfo;


    #[external(v0)]
    impl ConcreteV2 of super::AbstractV2<ContractState> {
        fn swap(
            ref self: ContractState,
            swap_info: SwapExactInfo,
            recipient: ContractAddress,
            market_id: u16
        ) {
            let wrapper = RouterWrapperDispatcher {
                contract_address: self.market_to_wrapper.read(market_id)
            };
            let caller = get_caller_address();
            IERC20Dispatcher { contract_address: swap_info.token_in }
                .transferFrom(caller, swap_info.pool, swap_info.amount_in_pool);

            wrapper.swap(swap_info, recipient);
        }

        fn get_amount_out(self: @ContractState, swap_info: SwapExactInfo, market_id: u16) -> u256 {
            let wrapper = RouterWrapperDispatcher {
                contract_address: self.market_to_wrapper.read(market_id)
            };
            return wrapper.get_amount_out(swap_info);
        }

        fn add_router(ref self: ContractState, router: ContractAddress) {
            let mkt_id: u16 = self._idx.read() + 1;
            self.market_to_wrapper.write(mkt_id, router);
            let wrapper = RouterWrapperDispatcher {
                contract_address: self.market_to_wrapper.read(mkt_id)
            };
            self._idx.write(mkt_id);
        }
    }
}
