// use starknet::ContractAddress;


// #[starknet::interface]
// trait ISignerLogic<TContractState> {
//     // Binds caller contract address (trading account) to signer.
//     // Signer is responsible for generating signature on behalf of caller address
//     fn bind_to_signer(ref self: TContractState, signer: ContractAddress);

//     // Validates that trader's  signer is correct signer of the message
//     fn check_sign(self: @TContractState, trader: ContractAddress, message: felt252, sig_r: felt252, sig_s: felt252) -> bool;
//     //  returns zero address in case of no binding
//     fn get_signer(self: @TContractState, trader: ContractAddress) -> ContractAddress;
//     //  returns zero address in case of no binding
//     fn get_signers(self: @TContractState, traders: Span<ContractAddress>) -> Array<ContractAddress>;
    
//     // TODO: later support rebinding 
// }

// #[starknet::component]
// mod signer_logic_component {
//     use core::option::OptionTrait;
//     use core::traits::TryInto;
//     use starknet::{ContractAddress, get_caller_address};
//     use ecdsa::check_ecdsa_signature;
//     use super::ISignerLogic;
//     use kurosawa_akira::utils::common::DisplayContractAddress;


//     #[event]
//     #[derive(Drop, starknet::Event)]
//     enum Event {
//         NewBinding: NewBinding
//     }

//     #[derive(Drop, starknet::Event)]
//     struct NewBinding {
//         #[key]
//         trading_account: ContractAddress,
//         #[key]
//         signer: ContractAddress,
//     }

//     #[storage]
//     struct Storage {
//         trader_to_signer: LegacyMap::<ContractAddress, ContractAddress>,
//     }

//     #[embeddable_as(Signable)]
//     impl SignableImpl<
//         TContractState, +HasComponent<TContractState>
//     > of ISignerLogic<ComponentState<TContractState>> {
        fn bind_to_signer(ref self: ComponentState<TContractState>, signer: ContractAddress) {
            let caller = get_caller_address();
            assert!(self.trader_to_signer.read(caller) == 0.try_into().unwrap(), "ALREADY BINDED: signer = {}", self.trader_to_signer.read(caller));
            self.trader_to_signer.write(caller, signer);
            self.emit(NewBinding { trading_account: caller, signer: signer });
        }

        fn get_signer(self: @ComponentState<TContractState>, trader: ContractAddress) -> ContractAddress {
            return self.trader_to_signer.read(trader);
        }

        // fn get_signers(self: @ComponentState<TContractState>, traders: Span<ContractAddress>) -> Array<ContractAddress> {
        //     //Note traders should not be empty
        //     let mut res: Array<ContractAddress> = ArrayTrait::new();
        //     let sz = traders.len();
        //     let mut idx = 0;
        //     loop {
        //         let trader = *traders.at(idx);
        //         res.append(self.trader_to_signer.read(trader));
        //         idx += 1;
        //         if (idx == sz) {
        //             break;
        //         }
        //     };
        //     return res;
        // }

        fn check_sign(self: @ComponentState<TContractState>, trader: ContractAddress, message: felt252, sig_r: felt252, sig_s: felt252) -> bool {
            let signer: ContractAddress = self.trader_to_signer.read(trader);
            assert!(signer != 0.try_into().unwrap(), "UNDEFINED_SIGNER: no signer for this trader {}", trader);
            return check_ecdsa_signature(message, signer.into(), sig_r, sig_s);
        }
    //}
//}

