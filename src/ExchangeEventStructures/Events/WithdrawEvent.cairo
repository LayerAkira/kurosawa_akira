use starknet::ContractAddress;
use serde::Serde;
use kurosawa_akira::ExchangeEventStructures::ExchangeEvent::Applying;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::_burn;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::_balance_read;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::apply_withdraw_started;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::user_balance_snapshot;
use kurosawa_akira::utils::erc20::IERC20DispatcherTrait;
use kurosawa_akira::utils::erc20::IERC20Dispatcher;

#[derive(Copy, Drop, Serde, starknet::Store)]
struct Withdraw {
    maker: ContractAddress,
    token: ContractAddress,
    amount: u256,
}

impl ApplyingWithdrawImpl of Applying<Withdraw> {
    fn apply(self: Withdraw){
        apply_withdraw_started();
        _burn(self.maker, self.amount, self.token);
        IERC20Dispatcher { contract_address: self.token }.transfer(self.maker, self.amount);
        user_balance_snapshot(self.maker, self.token, _balance_read((self.token, self.maker)));
    }
}
