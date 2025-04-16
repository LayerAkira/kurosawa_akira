
use kurosawa_akira::NonceComponent::{SignedIncreaseNonce, IncreaseNonce};
use kurosawa_akira::Order::{SignedOrder, Order};
use kurosawa_akira::WithdrawComponent::{SignedWithdraw, Withdraw};
    
    
#[starknet::interface]
trait ILayerAkiraExecutor<TContractState> {
    fn get_order_hash(self: @TContractState, order:Order) -> felt252;
    fn apply_increase_nonces(ref self: TContractState, signed_nonces: Array<SignedIncreaseNonce>, gas_price:u256);

    fn apply_increase_nonce(ref self: TContractState, signed_nonce: SignedIncreaseNonce, gas_price:u256, cur_gas_per_action:u32);

    fn apply_withdraw(ref self: TContractState, signed_withdraw: SignedWithdraw, gas_price:u256, cur_gas_per_action:u32);

    fn apply_withdraws(ref self: TContractState, signed_withdraws: Array<SignedWithdraw>, gas_price:u256, cur_gas_per_action:u32);

    fn apply_ecosystem_trades(ref self: TContractState, taker_orders:Array<(SignedOrder,bool)>, maker_orders: Array<SignedOrder>, iters:Array<(u16,bool)>, oracle_settled_qty:Array<u256>, gas_price:u256, cur_gas_per_action:u32);
    
    fn apply_single_execution_step(ref self: TContractState, taker_order:SignedOrder, maker_orders: Array<(SignedOrder,u256)>, total_amount_matched:u256,  gas_price:u256, cur_gas_per_action:u32, as_taker_completed:bool) -> bool;
    
    fn apply_execution_steps(ref self: TContractState, bulk:Array<(SignedOrder, Array<(SignedOrder,u256)>, u256,bool)>,  gas_price:u256, cur_gas_per_action:u32) -> Array<bool>;
}
