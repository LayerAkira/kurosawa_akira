use starknet::ContractAddress;
use serde::Serde;
use kurosawa_akira::ExchangeEntityStructures::ExchangeEntity::Applying;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::_burn;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::_balance_read;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::apply_withdraw_started;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::emit_apply_withdraw_started;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::user_balance_snapshot;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::emit_user_balance_snapshot;
use kurosawa_akira::utils::erc20::IERC20DispatcherTrait;
use kurosawa_akira::utils::erc20::IERC20Dispatcher;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::ContractState;
use kurosawa_akira::ExchangeEntityStructures::Entities::FundsTraits::check_sign;
use kurosawa_akira::ExchangeEntityStructures::Entities::FundsTraits::PoseidonHashImpl;

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
