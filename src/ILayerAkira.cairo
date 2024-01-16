
use starknet::{get_contract_address, ContractAddress};
use kurosawa_akira::Order::{SignedOrder,Order, OrderTradeInfo,OrderFee,FixedFee}; 
use kurosawa_akira::WithdrawComponent::{Withdraw,SignedWithdraw};
use kurosawa_akira::utils::SlowModeLogic::SlowModeDelay;
use kurosawa_akira::NonceComponent::SignedIncreaseNonce;

#[starknet::interface]
trait ILayerAkira<TContractState> {
    fn total_supply(self: @TContractState, token: ContractAddress) -> u256;

    fn balanceOf(self: @TContractState, address: ContractAddress, token: ContractAddress) -> u256;

    fn balancesOf(
        self: @TContractState, addresses: Span<ContractAddress>, tokens: Span<ContractAddress>
    ) -> Array<Array<u256>>;

    fn get_wrapped_native_token(self: @TContractState) -> ContractAddress;

    fn get_latest_gas_price(self: @TContractState)->u256;

    fn get_fee_recipient(self: @TContractState) -> ContractAddress;

    fn get_nonce(self: @TContractState, maker: ContractAddress) -> u32;
    fn get_nonces(self: @TContractState, makers: Span<ContractAddress>)-> Array<u32>;




    fn get_router(self:@TContractState, signer:ContractAddress) -> ContractAddress;
    fn get_route_amount(self:@TContractState) -> u256;

    fn router_deposit(ref self:TContractState, router:ContractAddress, coin:ContractAddress, amount:u256);
    
    //  native  token can be withdrawn up to amount specified to be eligible of being router
    fn router_withdraw(ref self: TContractState, coin: ContractAddress, amount: u256, receiver:ContractAddress);
    
    // register router so the required amount is holded while he is router
    fn register_router(ref self: TContractState);

    // if router wish to bind new signers
    fn add_router_binding(ref self: TContractState, signer: ContractAddress);

    // if some signer key gets compromised router can safely remove them
    fn remove_router_binding(ref self: TContractState, signer: ContractAddress);

    fn request_onchain_deregister(ref self: TContractState);
    
    fn apply_onchain_deregister(ref self: TContractState);

    // validates that message was signed by signer that mapped to router
    fn validate_router(self: @TContractState, message: felt252, signature: (felt252, felt252), signer: ContractAddress, router:ContractAddress) -> bool;

    // in case of failed action due to wrong taker we charge this amount
    fn get_punishment_factor_bips(self: @TContractState) -> u16;

    fn is_registered(self: @TContractState, router: ContractAddress) -> bool;

    fn have_sufficient_amount_to_route(self: @TContractState, router:ContractAddress) -> bool;

    fn balance_of_router(self:@TContractState, router:ContractAddress, coin:ContractAddress)->u256;




    fn get_safe_trade_info(self: @TContractState, order_hash: felt252) -> OrderTradeInfo;



    fn get_unsafe_trade_info(self: @TContractState, order_hash: felt252) -> OrderTradeInfo;




    fn request_onchain_withdraw(ref self: TContractState, withdraw: Withdraw);

    fn get_pending_withdraw(self:@TContractState, maker:ContractAddress,token:ContractAddress)->(SlowModeDelay,Withdraw);
    
    // can only be performed by the owner
    fn apply_onchain_withdraw(ref self: TContractState, token:ContractAddress, key:felt252);
    




    // Binds caller contract address to signer
    // So signer can execute trades on behalf of caller address 
    fn bind_to_signer(ref self: TContractState, signer: ContractAddress);

    // Validates that trader's  signer is correct signer of the message
    fn check_sign(
        self: @TContractState,
        trader: ContractAddress,
        message: felt252,
        sig_r: felt252,
        sig_s: felt252
    ) -> bool;
    //  returns zero address in case of no binding
    fn get_signer(self: @TContractState, trader: ContractAddress) -> ContractAddress;
    //  returns zero address in case of no binding
    fn get_signers(self: @TContractState, traders: Span<ContractAddress>) -> Array<ContractAddress>;


    fn deposit(ref self: TContractState, receiver:ContractAddress, token:ContractAddress, amount:u256);


    // layer akira

    fn apply_increase_nonce(ref self: TContractState, signed_nonce: SignedIncreaseNonce, gas_price:u256);

    fn apply_withdraw(ref self: TContractState, signed_withdraw: SignedWithdraw, gas_price:u256);

    fn apply_safe_trade(ref self: TContractState, taker_orders:Array<SignedOrder>, maker_orders: Array<SignedOrder>, iters:Array<(u8,bool)>, gas_price:u256);
    
    fn apply_unsafe_trade(ref self: TContractState, taker_order:SignedOrder, maker_orders: Array<SignedOrder>, total_amount_matched:u256,  gas_price:u256) -> bool; 
}