use kurosawa_akira::ExchangeEventStructures::Events::DepositEvent::Deposit;
use kurosawa_akira::ExchangeEventStructures::Events::WithdrawEvent::Withdraw;
use kurosawa_akira::ExchangeEventStructures::Events::TradeEvent::Trade;
use serde::Serde;

#[derive(Copy, Drop, Serde, starknet::Store)]
enum ExchangeEvent {
    Deposit: Deposit,
    Trade: Trade,
    Withdraw: Withdraw,
}

trait Applying<T> {
    fn apply(self: T);
}

impl ApplyingEventImpl of Applying<ExchangeEvent> {
    fn apply(self: ExchangeEvent){
        match self {
            ExchangeEvent::Deposit(x) => {
                x.apply();
            },
            ExchangeEvent::Trade(x) => {
                x.apply();
            },
            ExchangeEvent::Withdraw(x) => {
                x.apply();
            },
        }
    }
}
