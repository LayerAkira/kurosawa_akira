use starknet::ContractAddress;
use serde::Serde;
use kurosawa_akira::ExchangeEntityStructures::Entities::Order::SignedOrder;
use kurosawa_akira::utils::erc20::IERC20DispatcherTrait;
use kurosawa_akira::utils::erc20::IERC20Dispatcher;
use starknet::Store;


#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
struct Trade {
    maker_signed_order: SignedOrder,
    taker_signed_order: SignedOrder,
}
