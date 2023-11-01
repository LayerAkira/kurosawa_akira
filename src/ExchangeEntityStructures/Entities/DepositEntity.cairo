use starknet::ContractAddress;
use starknet::info::get_block_number;
use serde::Serde;
use kurosawa_akira::ExchangeEntityStructures::ExchangeEntity::Applying;
use kurosawa_akira::ExchangeEntityStructures::Entities::FundsTraits::Pending;
use kurosawa_akira::ExchangeEntityStructures::Entities::FundsTraits::Zeroable;
use kurosawa_akira::ExchangeEntityStructures::Entities::FundsTraits::check_sign;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::_balance_read;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::_pending_deposits_write;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::_pending_deposits_read;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::_pending_deposits_block_of_requested_cancellation_write;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::_pending_deposits_block_of_requested_cancellation_read;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::_waiting_gap_of_block_qty_read;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::_mint;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::apply_deposit_started;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::emit_apply_deposit_started;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::deposit_event;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::emit_deposit_event;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::user_balance_snapshot;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::emit_user_balance_snapshot;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::request_cancel_pending_deposit;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::emit_request_cancel_pending_deposit;
use starknet::info::get_caller_address;
use starknet::info::get_contract_address;
use kurosawa_akira::utils::erc20::IERC20DispatcherTrait;
use kurosawa_akira::utils::erc20::IERC20Dispatcher;
use kurosawa_akira::ExchangeEntityStructures::Entities::FundsTraits::PoseidonHash;
use starknet::{StorageBaseAddress, SyscallResult};
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::ContractState;
use starknet::Event;
use traits::Into;
#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
struct Deposit {
    maker: ContractAddress,
    receiver: ContractAddress,
    token: ContractAddress,
    amount: u256,
    salt: felt252,
}

#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
struct DepositApply {
    key: felt252,
    sign: (felt252, felt252),
}

impl ZeroableImpl of Zeroable<Deposit> {
    fn is_zero(self: Deposit) -> bool {
        self == self.zero()
    }
    fn zero(self: Deposit) -> Deposit {
        let zero_address = starknet::contract_address_try_from_felt252(0).unwrap();
        let zero_u256: u256 = 0;
        Deposit {
            maker: zero_address,
            receiver: zero_address,
            token: zero_address,
            amount: zero_u256,
            salt: 0
        }
    }
}


impl PendingImpl of Pending<Deposit> {
    fn set_pending(self: Deposit, ref state: ContractState) -> felt252 {
        let caller = get_caller_address();
        let contract = get_contract_address();
        assert(caller == self.maker, 'only deposits by user himself');
        assert(contract == self.receiver, 'only deposits to exchange');
        let pre = IERC20Dispatcher { contract_address: self.token }.balanceOf(contract);
        IERC20Dispatcher { contract_address: self.token }
            .transferFrom(self.maker, contract, self.amount);
        let fact_received = IERC20Dispatcher { contract_address: self.token }.balanceOf(contract)
            - pre;
        let key = self.get_poseidon_hash();
        let deposit = _pending_deposits_read(ref state, key);
        assert(deposit.is_zero(), 'already_pending');
        _pending_deposits_write(ref state, key, self);
        key
    }

    fn request_cancellation_pending(self: Deposit, ref state: ContractState) {
        let key = self.get_poseidon_hash();
        let deposit = _pending_deposits_read(ref state, key);
        assert(!deposit.is_zero(), 'not_pending');
        assert(
            _pending_deposits_block_of_requested_cancellation_read(ref state, key) == 0,
            'alrdy requseted'
        );
        let block_number = get_block_number();
        _pending_deposits_block_of_requested_cancellation_write(ref state, key, block_number);
        emit_request_cancel_pending_deposit(
            ref state, request_cancel_pending_deposit { deposit: self }
        )
    }

    fn cancel_pending(self: Deposit, ref state: ContractState) {
        let key = self.get_poseidon_hash();
        let deposit = _pending_deposits_read(ref state, key);
        assert(!deposit.is_zero(), 'not_pending');
        assert(
            _pending_deposits_block_of_requested_cancellation_read(ref state, key) != 0,
            'no cancel rqst'
        );
        let block_number = get_block_number();
        assert(
            _pending_deposits_block_of_requested_cancellation_read(ref state, key)
                + _waiting_gap_of_block_qty_read(ref state) < block_number,
            'early_cnsl'
        );
        _pending_deposits_block_of_requested_cancellation_write(ref state, key, 0);
        _pending_deposits_write(ref state, key, deposit.zero());
    }
}

trait ApplyingDeposit<T> {
    fn apply(self: T, ref state: ContractState);
}


impl ApplyingDepositImpl of ApplyingDeposit<DepositApply> {
    fn apply(self: DepositApply, ref state: ContractState) {
        emit_apply_deposit_started(ref state, apply_deposit_started {});
        let deposit = _pending_deposits_read(ref state, self.key);
        emit_deposit_event(ref state, deposit_event { deposit });
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
