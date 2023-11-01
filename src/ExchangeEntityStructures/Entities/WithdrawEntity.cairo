use starknet::ContractAddress;
use serde::Serde;
use starknet::info::get_block_number;
use starknet::info::get_caller_address;
use starknet::info::get_contract_address;
use kurosawa_akira::ExchangeEntityStructures::ExchangeEntity::Applying;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::_burn;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::_balance_read;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::_requested_onchain_withdraws_read;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::_requested_onchain_withdraws_write;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::_block_of_requested_action_read;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::_block_of_requested_action_write;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::apply_withdraw_started;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::emit_apply_withdraw_started;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::user_balance_snapshot;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::emit_user_balance_snapshot;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::request_onchain_withdraw;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::emit_request_onchain_withdraw;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::_waiting_gap_of_block_qty_read;
use kurosawa_akira::utils::erc20::IERC20DispatcherTrait;
use kurosawa_akira::utils::erc20::IERC20Dispatcher;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::ContractState;
use kurosawa_akira::ExchangeEntityStructures::Entities::FundsTraits::check_sign;
use kurosawa_akira::ExchangeEntityStructures::Entities::FundsTraits::OnchainWithdraw;
use kurosawa_akira::ExchangeEntityStructures::Entities::FundsTraits::PoseidonHashImpl;
use kurosawa_akira::ExchangeEntityStructures::Entities::FundsTraits::Zeroable;

#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
struct Withdraw {
    maker: ContractAddress,
    token: ContractAddress,
    amount: u256,
    salt: felt252,
}

#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
struct SignedWithdraw {
    withdraw: Withdraw,
    sign: (felt252, felt252),
}

impl ZeroableImpl of Zeroable<Withdraw> {
    fn is_zero(self: Withdraw) -> bool {
        self == self.zero()
    }
    fn zero(self: Withdraw) -> Withdraw {
        let zero_address = starknet::contract_address_try_from_felt252(0).unwrap();
        let zero_u256: u256 = 0;
        Withdraw { maker: zero_address, token: zero_address, amount: zero_u256, salt: 0 }
    }
}

impl ApplyingWithdrawImpl of Applying<SignedWithdraw> {
    fn apply(self: SignedWithdraw, ref state: ContractState) {
        emit_apply_withdraw_started(ref state, apply_withdraw_started {});
        let hash = self.withdraw.get_poseidon_hash();
        check_sign(self.withdraw.maker, hash, self.sign);
        _burn(ref state, self.withdraw.maker, self.withdraw.amount, self.withdraw.token);
        IERC20Dispatcher { contract_address: self.withdraw.token }
            .transfer(self.withdraw.maker, self.withdraw.amount);
        emit_user_balance_snapshot(
            ref state,
            user_balance_snapshot {
                user_address: self.withdraw.maker,
                token: self.withdraw.token,
                balance: _balance_read(ref state, (self.withdraw.token, self.withdraw.maker))
            }
        );
    }
}

impl OnchainWithdrawImpl of OnchainWithdraw<Withdraw> {
    fn request_onchain_withdraw(self: Withdraw, ref state: ContractState) {
        let key = self.get_poseidon_hash();
        let withdraw = _requested_onchain_withdraws_read(ref state, key);
        let caller = get_caller_address();
        assert(caller == self.maker, 'only by user himself');
        assert(withdraw.is_zero(), 'alry_requested');
        let block_number = get_block_number();
        _block_of_requested_action_write(ref state, key, block_number);
        emit_request_onchain_withdraw(ref state, request_onchain_withdraw { withdraw: self })
    }
    fn make_onchain_withdraw(self: Withdraw, ref state: ContractState) {
        let key = self.get_poseidon_hash();
        let withdraw = _requested_onchain_withdraws_read(ref state, key);
        let caller = get_caller_address();
        assert(caller == self.maker, 'only by user himself');
        assert(!withdraw.is_zero(), 'not_requested');
        let block_number = get_block_number();
        assert(
            _block_of_requested_action_read(ref state, key)
                + _waiting_gap_of_block_qty_read(ref state) <= block_number,
            'early_make'
        );
        _block_of_requested_action_write(ref state, key, 0);
        _requested_onchain_withdraws_write(ref state, key, self.zero());
        _burn(ref state, self.maker, self.amount, self.token);
        IERC20Dispatcher { contract_address: self.token }.transfer(self.maker, self.amount);
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

