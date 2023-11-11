use serde::Serde;
use starknet::ContractAddress;
use starknet::contract_address_to_felt252;
use array::ArrayTrait;

use kurosawa_akira::V2_pools::RouterWrapper::RouterWrapper;
use kurosawa_akira::V2_pools::RouterWrapper::SwapExactInfo;

use debug::PrintTrait;

use kurosawa_akira::V2_pools::RouterWrapper::AbstractV2Dispatcher;
use kurosawa_akira::V2_pools::RouterWrapper::AbstractV2DispatcherTrait;
use kurosawa_akira::V2_pools::RouterWrapper::RouterWrapperDispatcher;
use kurosawa_akira::V2_pools::RouterWrapper::RouterWrapperDispatcherTrait;
use kurosawa_akira::V2_pools::RouterWrapper::ConcreteV2;

#[cfg(test)]
mod tests {
    use core::traits::Into;
    use core::array::ArrayTrait;
    use core::option::OptionTrait;
    use core::traits::TryInto;
    use core::result::ResultTrait;
    use snforge_std::declare;
    use starknet::ContractAddress;
    use snforge_std::ContractClassTrait;
    use super::RouterWrapperDispatcher;
    use super::RouterWrapperDispatcherTrait;

    use super::AbstractV2Dispatcher;
    use super::AbstractV2DispatcherTrait;
    use super::SwapExactInfo;

    use starknet::info::get_block_number;
    use debug::PrintTrait;
    use starknet::get_caller_address;

    use snforge_std::start_prank;
        use snforge_std::stop_prank;
    use kurosawa_akira::utils::erc20::IERC20DispatcherTrait;
    use kurosawa_akira::utils::erc20::IERC20Dispatcher;
    use kurosawa_akira::V2_pools::RouterWrapper::ConcreteV2;


    #[test]
    #[available_gas(10000000000)]
    #[fork("forked")]
    fn add_two_and_two() {
        let contract = declare('ConcreteV2');
        let c: ContractAddress = 0x041fd22b238fa21cfcf5dd45a8548974d8263b3a531a60388411c5e230f97023
            .try_into()
            .unwrap();
        let contract_address = contract.deploy(@ArrayTrait::new()).unwrap();

        // Create a Dispatcher object that will allow interacting with the deployed contract
        let dispatcher = AbstractV2Dispatcher { contract_address: contract_address };
        let zero_address: ContractAddress = starknet::contract_address_try_from_felt252(0).unwrap();

        let dummy_wrapper_cls = declare('JediWrapper');
        let mut constructor: Array::<felt252> = ArrayTrait::new();
        constructor.append(c.into());
        let dummy_wrapper_contract = dummy_wrapper_cls.deploy(@constructor).unwrap();
        let dummy_wrapper = RouterWrapperDispatcher { contract_address: dummy_wrapper_contract };

        let usdc_token:ContractAddress = 0x53c91253bc9682c04929ca02ed00b3e423f6710d2ee7e0d5ebb06f3ecf368a8.try_into().unwrap();
        let usdt_token:ContractAddress = 0x68f5c6a61780768455de69077e07e89787839bf8166decfbf92b645209c0fb8.try_into().unwrap();
        let pool:ContractAddress = 0x05801bdad32f343035fb242e98d1e9371ae85bc1543962fedea16c59b35bd19b.try_into().unwrap();
        let mut s = SwapExactInfo {
            amount_in_pool: 100_0000,
            amount_out_min: 0,
            token_in: usdt_token,
            token_out: usdc_token,
            pool: pool,
        };
        dispatcher.add_router(dummy_wrapper_contract);
        
        let expected_receive = dispatcher.get_amount_out(s, 1);
        s.amount_out_min = expected_receive;  


        //#myswap actually
        let caller_who_have_funds: ContractAddress = 0x00000005dd3d2f4429af886cd1a3b08289dbcea99a294197e9eb43b0e0325b4b.try_into().unwrap();
        let erc20 = IERC20Dispatcher{contract_address: usdt_token};
        
        
        start_prank(erc20.contract_address, caller_who_have_funds);  
        
        
        erc20.approve(contract_address, s.amount_in_pool);
        stop_prank(usdt_token);

        start_prank(contract_address, caller_who_have_funds);  
        let received_erc20 = IERC20Dispatcher{contract_address: usdc_token};
        let receiver: ContractAddress = 1.try_into().unwrap();
        
        received_erc20.balanceOf(receiver).print();
        
        dispatcher.swap(s, receiver, 1);
        received_erc20.balanceOf(receiver).print();

        // s.amount_out_min.print();
        // erc20.allowance(erc20.contract_address,contract_address).print();
        // start_prank(erc20.contract_address,contract_address); 
        // erc20.transferFrom(caller_who_have_funds,contract_address,1);
        
        // start_prank(contract_address,caller_who_have_funds);      
        // erc20.transferFrom(caller_who_have_funds, contract_address, s.amount_in_pool);
        
        // dispatcher.swap(s, get_caller_address(), 1);
        // dummy_wrapper.swap(0, 0, zero_address, zero_address, zero_address, zero_address);
        // let result = dispatcher.get_amount_out(0,zero_address,zero_address,zero_address,2);
        // let res = dummy_wrapper.get_amount_out(0, zero_address, zero_address, zero_address);
        // assert(dispatcher.get_amount_out(s,1) == 528253273744, 'result is not 42');
    }
}
// 390816