use starknet::ContractAddress;
use kurosawa_akira::ExchangeBalance::{NewGasFee,get_gas_fee_and_coin};
use serde::Serde;
use kurosawa_akira::utils::SlowModeLogic::SlowModeDelay;

#[starknet::interface]
trait IRouter<TContractState> {

    fn router_deposit(ref self:TContractState, router:ContractAddress, coin:ContractAddress, amount:u256);
    
    //  native  token can be withdrawn up to amount specified to be eligible of being router
    fn router_withdraw(ref self: TContractState, coin: ContractAddress, amount: u256, receiver:ContractAddress);
    
    // register router so the required amount is holded while he is router
    fn register_router(ref self: TContractState);

    // if router wish to bind new signers
    fn add_binding(ref self: TContractState, signer: ContractAddress);

    // if some signer key gets compromised router can safely remove them
    fn remove_binding(ref self: TContractState, signer: ContractAddress);

    fn request_onchain_unregister(ref self: TContractState);
    
    fn apply_onchain_unregister(ref self: TContractState);

    // validates that message was signed by signer that mapped to router
    fn validate_router(self: @TContractState, message: felt252, signature: (felt252, felt252), signer: ContractAddress, router:ContractAddress) -> bool;

    // in case of failed action due to wrong taker we charge this amount
    fn get_punishment_factor_bips(self: @TContractState) -> u256;

    fn is_registered(self: @TContractState, router: ContractAddress) -> bool;

    fn have_sufficient_amount_to_route(self: @TContractState, router:ContractAddress) -> bool;

    fn balance_of_router(self:@TContractState, router:ContractAddress, coin:ContractAddress)->u256;
}


#[starknet::component]
mod router_component {
    use ecdsa::check_ecdsa_signature;    
    use super::{IRouter,ContractAddress,SlowModeDelay};
    use starknet::{get_caller_address,get_contract_address,get_block_timestamp};
    use starknet::info::get_block_number;
    use kurosawa_akira::utils::erc20::{IERC20DispatcherTrait, IERC20Dispatcher};
    



    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        Deposit:  Deposit,
        Withdraw: Withdraw,
        RouterRegistration:Registration,
        Binding:Binding
    }

    #[derive(Drop, starknet::Event)]
    struct Deposit {
        #[key]
        router: ContractAddress,
        #[key]
        token: ContractAddress,
        funder: ContractAddress,
        amount: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct Withdraw {
        #[key]
        router:ContractAddress,
        #[key]
        token:ContractAddress,
        amount:u256,
        receiver:ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct Registration {
        #[key]
        router:ContractAddress,
        status: u8, //0registered,1scheduled unregister,2unregsiter
    }
    #[derive(Drop, starknet::Event)]
    struct Binding {
        #[key]
        router:ContractAddress,
        #[key]
        signer:ContractAddress,
        is_added:bool
    }




    #[storage]
    struct Storage {
        pending_unregister:LegacyMap::<felt252, SlowModeDelay>,
        delay: SlowModeDelay, // set by exchange, can be updated but no more then original
 
        min_to_route:u256,
        token_to_user:LegacyMap::<(ContractAddress,ContractAddress),u256>,
        registered:LegacyMap::<ContractAddress,bool>,
        native_base_token:ContractAddress,
        signer_to_router:LegacyMap<ContractAddress,ContractAddress>,
        pinishment_bips:u256

        
    }

    #[embeddable_as(Routable)]
    impl RoutableImpl<TContractState, +HasComponent<TContractState>> of super::IRouter<ComponentState<TContractState>> {
        
        fn router_deposit(ref self:ComponentState<TContractState>, router:ContractAddress, coin:ContractAddress, amount:u256) {
            let erc20 = IERC20Dispatcher{contract_address: coin};
            let contract_addr =  get_contract_address();
            let caller = get_caller_address();
            
            let pre = erc20.balanceOf(contract_addr);
            erc20.transferFrom(caller, contract_addr, amount);
            assert(erc20.balanceOf(contract_addr) - pre == amount, 'WRING_TFER');
            
            self.token_to_user.write((coin,router),self.token_to_user.read((coin,router)) + amount);
            self.emit(Deposit{router:router,token:coin,funder:caller,amount:amount});
        }

        fn router_withdraw(ref self: ComponentState<TContractState>, coin: ContractAddress, amount: u256, receiver:ContractAddress) {
            let router = get_caller_address();
            let balance:u256 = self.token_to_user.read((coin,router)); 
            assert(balance >= amount, 'FEW_COINS');
            assert(self.registered.read(router) || balance - amount >= 2 * self.min_to_route.read(), 'FEW_FOR_ROUTE');

            self.token_to_user.write((coin,router), balance - amount);
            let erc20 = IERC20Dispatcher{contract_address: coin};
            erc20.transfer(receiver,amount);
            self.emit(Withdraw{router:router,token:coin,amount:amount,receiver:receiver});
        }

        fn register_router(ref self: ComponentState<TContractState>) {
            let caller = get_caller_address();
            assert(!self.registered.read(caller) ,'ALREADY_REGISTERED');
            let native_balance = self.token_to_user.read( (self.native_base_token.read(), caller));
            assert(native_balance >= 2 * self.min_to_route.read(), 'FEW_DEPOSITED');
            self.registered.write(caller, true);
            self.emit(Registration{router:caller,status:0});
        }

        fn add_binding(ref self: ComponentState<TContractState>, signer: ContractAddress){
            let router = get_caller_address();
            assert(self.registered.read(router) ,'NOT_REGISTERED');
            let cur_router = self.signer_to_router.read(signer);
            assert(!self.registered.read(cur_router), 'ALREADY_USED');
            self.signer_to_router.write(signer,router);
            self.emit(Binding{router,signer,is_added:true});
        }

        fn remove_binding(ref self: ComponentState<TContractState>, signer: ContractAddress){
            let router = get_caller_address();
            assert(self.registered.read(router) ,'NOT_REGISTERED');
            let cur_router = self.signer_to_router.read(signer);
            assert(cur_router == router, 'WRONG_BINDING');
            self.signer_to_router.write(signer, 0.try_into().unwrap());
            self.emit(Binding{router,signer,is_added:false});
        }



        fn request_onchain_unregister(ref self: ComponentState<TContractState>) {
            let router = get_caller_address();
            assert(self.registered.read(router), 'NOT_REGISTERED');
            let ongoing:SlowModeDelay = self.pending_unregister.read(router.into());
            assert(ongoing.block == 0, 'ALREADY_REQUESTED');
            self.pending_unregister.write(router.into(), SlowModeDelay{block:get_block_number(),ts:get_block_timestamp()});
            self.emit(Registration{router:router,status:1});
        }
         
        fn apply_onchain_unregister(ref self: ComponentState<TContractState>) {
            let router = get_caller_address();
            assert(self.registered.read(router), 'NOT_REGISTERED');
            let ongoing:SlowModeDelay = self.pending_unregister.read(router.into());
            assert(ongoing.block != 0, 'NOT_REQUESTED');
            let delay:SlowModeDelay = self.delay.read();
            assert(get_block_number() - ongoing.block >= delay.block && get_block_timestamp() - ongoing.ts >= delay.ts,'FEW_TIME_PASSED');
            
            self.registered.write(router, false);
            self.pending_unregister.write(router.into(), SlowModeDelay{block:0,ts:0});
            self.emit(Registration{router:router,status:2});
        }

        fn validate_router(self: @ComponentState<TContractState>, message: felt252, signature: (felt252, felt252), signer: ContractAddress, router:ContractAddress) -> bool {
            let actual_router = self.signer_to_router.read(signer);
            if actual_router != router {return false;}
            assert(self.registered.read(router),'NOT_REGISTERED');
            let (sig_r,sig_s) = signature;
            return check_ecdsa_signature(message, signer.into(), sig_r, sig_s);
        }


        fn get_punishment_factor_bips(self: @ComponentState<TContractState>) -> u256 { return self.pinishment_bips.read();}

        
        fn is_registered(self: @ComponentState<TContractState>, router: ContractAddress) -> bool{ return self.registered.read(router);}

        fn have_sufficient_amount_to_route(self: @ComponentState<TContractState>, router:ContractAddress) -> bool {
            return self.token_to_user.read((self.native_base_token.read(),router)) >= self.min_to_route.read();
        }

        fn balance_of_router(self:@ComponentState<TContractState>, router:ContractAddress, coin:ContractAddress)-> u256 {
            return self.token_to_user.read((coin,router));
        }
    }

}
