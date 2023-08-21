use starknet::ContractAddress;
use serde::Serde;
use kurosawa_akira::ExchangeEventStructures::ExchangeEvent::Applying;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::_balance_read;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::_mint;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::apply_deposit_started;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::user_balance_snapshot;

#[derive(Copy, Drop, Serde, starknet::Store)]
struct Deposit {
    maker: ContractAddress,
    token: ContractAddress,
    amount: u256,
    validation_info: felt252,
}

impl ApplyingDepositImpl of Applying<Deposit> {
    fn apply(self: Deposit){
        apply_deposit_started();
        _mint(self.maker, self.amount, self.token);
        user_balance_snapshot(self.maker, self.token, _balance_read((self.token, self.maker)));
    }
}
