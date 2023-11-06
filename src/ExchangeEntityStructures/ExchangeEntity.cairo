use kurosawa_akira::ExchangeEntityStructures::Entities::DepositEntity::DepositApply;
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
