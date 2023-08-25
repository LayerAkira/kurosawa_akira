use starknet::ContractAddress;
use serde::Serde;
use kurosawa_akira::ExchangeEventStructures::ExchangeEvent::Applying;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::_burn;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::_balance_read;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::apply_withdraw_started;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::emit_apply_withdraw_started;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::user_balance_snapshot;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::emit_user_balance_snapshot;
use kurosawa_akira::utils::erc20::IERC20DispatcherTrait;
use kurosawa_akira::utils::erc20::IERC20Dispatcher;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::ContractState;

#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
struct Withdraw {
    maker: ContractAddress,
    token: ContractAddress,
    amount: u256,
}

impl ApplyingWithdrawImpl of Applying<Withdraw> {
    fn apply(self: Withdraw, ref state: ContractState) {
        emit_apply_withdraw_started(ref state, apply_withdraw_started {});
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
