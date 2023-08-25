use kurosawa_akira::ExchangeEventStructures::Events::DepositEvent::DepositApply;
use kurosawa_akira::ExchangeEventStructures::Events::DepositEvent::ApplyingDeposit;
use kurosawa_akira::ExchangeEventStructures::Events::WithdrawEvent::Withdraw;
use kurosawa_akira::ExchangeEventStructures::Events::TradeEvent::Trade;
use serde::Serde;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::ContractState;

#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
enum ExchangeEvent {
    DepositApply: DepositApply,
    Trade: Trade,
    Withdraw: Withdraw,
}

trait Applying<T> {
    fn apply(self: T, ref state: ContractState);
}

impl ApplyingEventImpl of Applying<ExchangeEvent> {
    fn apply(self: ExchangeEvent, ref state: ContractState) {
        match self {
            ExchangeEvent::DepositApply(x) => {
                x.apply(ref state);
            },
            ExchangeEvent::Trade(x) => {
                x.apply(ref state);
            },
            ExchangeEvent::Withdraw(x) => {
                x.apply(ref state);
            },
        }
    }
}
