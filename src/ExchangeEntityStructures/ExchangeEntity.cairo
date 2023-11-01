use kurosawa_akira::ExchangeEntityStructures::Entities::DepositEntity::DepositApply;
use kurosawa_akira::ExchangeEntityStructures::Entities::DepositEntity::ApplyingDeposit;
use kurosawa_akira::ExchangeEntityStructures::Entities::WithdrawEntity::SignedWithdraw;
use kurosawa_akira::ExchangeEntityStructures::Entities::TradeEntity::Trade;
use serde::Serde;
use kurosawa_akira::AKIRA_exchange::AKIRA_exchange::ContractState;

#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
enum ExchangeEntity {
    DepositApply: DepositApply,
    Trade: Trade,
    SignedWithdraw: SignedWithdraw,
}

trait Applying<T> {
    fn apply(self: T, ref state: ContractState);
}

impl ApplyingEntityImpl of Applying<ExchangeEntity> {
    fn apply(self: ExchangeEntity, ref state: ContractState) {
        match self {
            ExchangeEntity::DepositApply(x) => { x.apply(ref state); },
            ExchangeEntity::Trade(x) => { x.apply(ref state); },
            ExchangeEntity::SignedWithdraw(x) => { x.apply(ref state); },
        }
    }
}
