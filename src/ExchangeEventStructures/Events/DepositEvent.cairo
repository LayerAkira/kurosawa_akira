use starknet::ContractAddress;
use serde::Serde;
use kurosawa_akira::ExchangeEventStructures::ExchangeEvent::Applying;
use kurosawa_akira::ExchangeEventStructures::Events::FundsTraits::Pending;
use kurosawa_akira::ExchangeEventStructures::Events::FundsTraits::Zeroable;
use kurosawa_akira::ExchangeEventStructures::Events::FundsTraits::check_sign;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::_balance_read;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::_pending_deposits_write;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::_pending_deposits_read;
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
use traits::Into;
#[derive(Copy, Drop, Serde, starknet::Store, PartialEq, Zeroable)]
struct Deposit {
    maker: ContractAddress,
    receiver: ContractAddress,
    token: ContractAddress,
    amount: u256,
    salt: felt252,
}

#[derive(Copy, Drop, Serde, starknet::Store, PartialEq, Zeroable)]
struct DepositApply {
    key: felt252,
    sign: (felt252, felt252),
}

impl ZeroableImpl of Zeroable<Deposit> {
    fn is_zero(self: Deposit) -> bool {
        let mut res: bool = true;
        if self.maker.into() == 0 {
            res = false;
        }
        if self.receiver.into() == 0 {
            res = false;
        }
        if self.token.into() == 0 {
            res = false;
        }
        if self.amount.into() == 0 {
            res = false;
        }
        if self.salt.into() == 0 {
            res = false;
        }
        res
    }
    fn zero(self: Deposit) -> Deposit {
        let zero_adress = starknet::contract_address_try_from_felt252(0).unwrap();
        let zero_u256: u256 = 0;
        Deposit{maker: zero_adress, receiver: zero_adress, token: zero_adress, amount: zero_u256, salt: 0}
    }
}


impl PendingImpl of Pending<Deposit> {
    fn set_pending(self: Deposit, ref state: ContractState) -> felt252 {
        let caller = get_caller_address();
        let contract = get_contract_address();
        assert(caller == self.maker, 'only deposits by user himself');
        assert(contract == self.receiver, 'only deposits to exchange');
        let pre = IERC20Dispatcher { contract_address: self.token }.balance_of(contract);
        IERC20Dispatcher { contract_address: self.token }
            .transfer_from(self.maker, contract, self.amount);
        let fact_received = IERC20Dispatcher { contract_address: self.token }.balance_of(contract)
            - pre;
        let key = self.get_poseidon_hash();
        let deposit = _pending_deposits_read(ref state, key);
        assert(deposit.is_zero(), 'already_pending');
        _pending_deposits_write(ref state, key, self);
        key
    }
}

trait ApplyingDeposit<T> {
    fn apply(self: T, ref state: ContractState);
}



impl ApplyingDepositImpl of ApplyingDeposit<DepositApply> {
    fn apply(self: DepositApply, ref state: ContractState) {
        emit_apply_deposit_started(ref state, apply_deposit_started {});
        let deposit = _pending_deposits_read(ref state, self.key);
        check_sign(deposit.maker, self.key, self.sign);
        _mint(ref state, deposit.maker, deposit.amount, deposit.token);
        _pending_deposits_write(ref state, self.key, deposit.zero());
        emit_user_balance_snapshot(
            ref state,
            user_balance_snapshot {
                user_address: deposit.maker,
                token: deposit.token,
                balance: _balance_read(ref state, (deposit.token, deposit.maker))
            }
        );
    }
}
