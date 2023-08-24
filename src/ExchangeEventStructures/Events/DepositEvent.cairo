use starknet::ContractAddress;
use serde::Serde;
use kurosawa_akira::ExchangeEventStructures::ExchangeEvent::Applying;
use kurosawa_akira::ExchangeEventStructures::Events::FundsTraits::Pending;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::_balance_read;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::_mint;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::apply_deposit_started;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::emit_apply_deposit_started;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::user_balance_snapshot;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::emit_user_balance_snapshot;
use starknet::info::get_caller_address;
use starknet::info::get_contract_address;
use kurosawa_akira::utils::erc20::IERC20DispatcherTrait;
use kurosawa_akira::utils::erc20::IERC20Dispatcher;
use kurosawa_akira::ExchangeEventStructures::Events::FundsTraits::PoseidonHash;
use starknet::{StorageBaseAddress, SyscallResult};
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::ContractState;
use starknet::Event;

#[derive(Copy, Drop, Serde, starknet::Store)]
struct Deposit {
    maker: ContractAddress,
    receiver: ContractAddress,
    token: ContractAddress,
    amount: u256,
    salt: felt252,
}


impl PendingImpl of Pending<Deposit> {
    fn set_pending(self: Deposit) {
        let caller = get_caller_address();
        let contract = get_contract_address();
        assert(caller == self.maker, 'only deposits by user himself');
        let pre = IERC20Dispatcher { contract_address: self.token }.balance_of(contract);
        IERC20Dispatcher { contract_address: self.token }
            .transfer_from(self.maker, contract, self.amount);
        let fact_received = IERC20Dispatcher { contract_address: self.token }.balance_of(contract)
            - pre;
        let key = self.get_poseidon_hash();
    }
}

impl ApplyingDepositImpl of Applying<Deposit> {
    fn apply(self: Deposit, ref state: ContractState) {
        emit_apply_deposit_started(ref state, apply_deposit_started {});
        _mint(ref state, self.maker, self.amount, self.token);
        emit_user_balance_snapshot(
            ref state,
            user_balance_snapshot {
                user_address: self.maker,
                token: self.token,
                balance: _balance_read(ref state, (self.token, self.maker))
            }
        );
    }
}
