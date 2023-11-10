use serde::Serde;
use starknet::ContractAddress;
    use starknet::contract_address_to_felt252;
    use array::ArrayTrait;


#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
struct SwapExactInfo {
        amount_in: u256,
        amount_out_min: u256,
        token_in: ContractAddress,
        token_out: ContractAddress,
        to: ContractAddress,
        deadline: felt252,
}


#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
struct JediSwapRouter {
        address: ContractAddress,
}

#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
struct MySwapRouter {
        address: ContractAddress,
}

#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
struct RandomSwapRouter {
        address: ContractAddress,
}

trait ExactSwapTrait<T> {
    fn swap_exact_tokens_for_tokens(self: T,
        info: SwapExactInfo
    ) -> u256;
}

#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
enum V2Swapper {
    JediSwap: JediSwapRouter,
    MySwap: MySwapRouter,
    RandomSwap: RandomSwapRouter,
}

#[starknet::interface]
trait IJediSwapRouterContract<TContractState> {
    fn swap_exact_tokens_for_tokens(ref self: TContractState, amountIn: u256, amountOutMin: u256, path: Array::<felt252>, to: felt252, deadline: felt252) -> u256;
}



impl JediSwapExactSwapTraitImpl of ExactSwapTrait<JediSwapRouter> {
    fn swap_exact_tokens_for_tokens(
        self: JediSwapRouter, info: SwapExactInfo
    ) -> u256{
        let mut path: Array::<felt252> = ArrayTrait::new();
        path.append(contract_address_to_felt252(info.token_in));
        path.append(contract_address_to_felt252(info.token_out));
        return IJediSwapRouterContractDispatcher{contract_address:self.address}.swap_exact_tokens_for_tokens(
        info.amount_in,
        info.amount_out_min,
        path,
        contract_address_to_felt252(info.to),
        info.deadline,
        );
    }
}

impl MySwapExactSwapTraitImpl of ExactSwapTrait<MySwapRouter> {
    fn swap_exact_tokens_for_tokens(
        self: MySwapRouter, info: SwapExactInfo
    ) -> u256{
        0
    }
}


impl RandomSwapExactSwapTraitImpl of ExactSwapTrait<RandomSwapRouter> {
    fn swap_exact_tokens_for_tokens(
        self: RandomSwapRouter, info: SwapExactInfo
    ) -> u256{
        0
    }
}



impl ExactSwapTraitImpl of ExactSwapTrait<V2Swapper> {
    fn swap_exact_tokens_for_tokens(
        self: V2Swapper, info: SwapExactInfo
    ) -> u256{
        match self {
            V2Swapper::JediSwap(x) => {
                return x.swap_exact_tokens_for_tokens(info);
            },
            V2Swapper::MySwap(x) => {
                return x.swap_exact_tokens_for_tokens(info);
            },
            V2Swapper::RandomSwap(x) => {
                return x.swap_exact_tokens_for_tokens(info);
            },
        }
    }
}

#[starknet::interface]
trait ISimpleV2SwapperContract<TContractState> {
    #[external(v0)]
    fn swap_exact_amounts(
        ref self: TContractState,
        swapper: V2Swapper,
        info: SwapExactInfo,
    ) -> u256;
}


#[starknet::contract]
mod SimpleV2SwapperContract {
    use starknet::ContractAddress;
    use starknet::get_caller_address;
    use starknet::get_contract_address;
    use starknet::info::get_block_timestamp;
    use starknet::info::get_block_number;
    use starknet::contract_address_to_felt252;
    use kurosawa_akira::utils::erc20::IERC20DispatcherTrait;
    use kurosawa_akira::utils::erc20::IERC20Dispatcher;
    use integer::u256_from_felt252;
    use super::V2Swapper;
    use super::SwapExactInfo;
    use super::ExactSwapTraitImpl;

    #[storage]
    struct Storage {
    }


    #[constructor]
    fn constructor(ref self: ContractState) {
    }


    #[external(v0)]
    fn swap_exact_amounts(
        ref self: ContractState,
        swapper: V2Swapper,
        info: SwapExactInfo,
    ) -> u256 {
        let caller = get_caller_address();
        IERC20Dispatcher { contract_address: info.token_in }.transferFrom(caller, get_contract_address(), info.amount_in);
        let router_address: ContractAddress = match swapper {
            V2Swapper::JediSwap(x) => {
                x.address
            },
            V2Swapper::MySwap(x) => {
                x.address
            },
            V2Swapper::RandomSwap(x) => {
                x.address
            },
        };
        IERC20Dispatcher { contract_address: info.token_in }.approve(router_address, info.amount_in);
        let amount_out = swapper.swap_exact_tokens_for_tokens(info);
        return amount_out;
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        ab: ab
    }

    #[derive(Drop, starknet::Event)]
    struct ab {
    }
}
