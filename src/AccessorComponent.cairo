use starknet::{ContractAddress, get_caller_address};

#[starknet::interface]
trait IAccesorableImpl<TContractState> {
        // returns global and user epoch; for the backend use
        fn get_epochs(self: @TContractState, executor: ContractAddress, user:ContractAddress) -> (u32, u32);
        // returns owner of the contract
        fn get_owner(self: @TContractState) -> ContractAddress;
        // Is client approved the specified executor 
        fn is_approved_executor(self: @TContractState, executor:ContractAddress, user:ContractAddress) -> bool;
        // only owner can update owner
        fn set_owner(ref self: TContractState, new_owner:ContractAddress);
        // wlist or dewlist executor; in case of dewlist approvals reset for everybody to avoid any malisious actions with renewable later on
        fn update_executor(ref self: TContractState, new_executor:ContractAddress, wlist:bool);
        // invoked by client to whitelist current executor to perform actions on his behalf
        fn grant_access_to_executor(ref self: TContractState, executor:ContractAddress);
        // invoked by the owner; invalidates all client approvals; eg malicous executor/bug/other stuff
        fn invalidate_executors(ref self: TContractState);
}



#[starknet::component]
mod accessor_logic_component {
    use super::{ContractAddress, get_caller_address};
    use super::{IAccesorableImpl};


    #[storage]
    struct Storage {
        owner: ContractAddress, // owner of contact that have permissions to grant and revoke role for executors 
        user_to_executor_to_epoch: starknet::storage::Map::<(ContractAddress, ContractAddress), u32>, 
        wlsted_executors:starknet::storage::Map::<ContractAddress, bool>, //wlisted executers by the owner
        global_executor_epoch:u32 // epoch that controls is enabled  
    }


    #[embeddable_as(Accesorable)]
    impl AccsesorableImpl<TContractState, +HasComponent<TContractState>> of IAccesorableImpl<ComponentState<TContractState>> {
        
        fn get_epochs(self: @ComponentState<TContractState>, executor: ContractAddress, user:ContractAddress) -> (u32, u32) {
            (self.global_executor_epoch.read(), self.user_to_executor_to_epoch.read((user, executor)))
        }

        fn is_approved_executor(self: @ComponentState<TContractState>, executor:ContractAddress, user:ContractAddress) -> bool {
            let (actual_epoch, client_epoch) = self.get_epochs(executor, user);
            actual_epoch == client_epoch && self.wlsted_executors.read(executor)
        }

        fn get_owner(self: @ComponentState<TContractState>) -> ContractAddress { self.owner.read()}
    
    
        fn set_owner(ref self: ComponentState<TContractState>, new_owner:ContractAddress) {
            self.only_owner();
            self.owner.write(new_owner);
            self.emit(OwnerChanged{new_owner});
        }

        fn update_executor(ref self: ComponentState<TContractState>, new_executor:ContractAddress, wlist:bool) {
            self.only_owner();
            assert(self.wlsted_executors.read(new_executor) != wlist, 'Executor already added/removed');
            self.wlsted_executors.write(new_executor, wlist);
            self.emit(ExecutorChanged{new_executor, new_epoch:self.global_executor_epoch.read(), wlisted:wlist});
            if (!wlist) {self.invalidate_executors()};
        }

        fn grant_access_to_executor(ref self: ComponentState<TContractState>, executor:ContractAddress) { 
            assert(self.wlsted_executors.read(executor), 'Executor not wlsed');
            let client_epoch = self.user_to_executor_to_epoch.read((get_caller_address(), executor));
            let global_epoch = self.global_executor_epoch.read();
            assert(client_epoch < global_epoch, 'Already granted');
            self.user_to_executor_to_epoch.write((get_caller_address(), executor), global_epoch);
            self.emit(ApprovalGranted{executor, user:get_caller_address(), epoch:global_epoch })
        }
        
        fn invalidate_executors(ref self: ComponentState<TContractState>) { 
            self.only_owner();
            self.global_executor_epoch.write(self.global_executor_epoch.read() + 1);
            self.emit(GlobalEpoch{epoch:self.global_executor_epoch.read()})
        }
    }

    
    #[generate_trait]
    impl InternalAccesorableImpl<TContractState, +HasComponent<TContractState>> of InternalAccesorable<TContractState> {
        
        fn only_authorized_by_user(self: @ComponentState<TContractState>, user:ContractAddress, executor:ContractAddress) {
            assert!(self.is_approved_executor(executor, user), "Access denied: only authorized by user")}
        fn only_owner(self: @ComponentState<TContractState>) { 
            assert!(self.owner.read() == get_caller_address(), "Access denied: only for the owner's use");}
        fn only_executor(self: @ComponentState<TContractState>) { 
            assert(self.wlsted_executors.read(get_caller_address()), 'Access denied: only executor');}
        fn only_owner_or_executor(self: @ComponentState<TContractState> ) {
            assert!(self.owner.read() == get_caller_address() || self.wlsted_executors.read(get_caller_address()), "Access denied: only for the owner's or executor's use");}
        
    }



    #[derive(Drop, starknet::Event)]
    struct OwnerChanged {new_owner:ContractAddress}
    #[derive(Drop, starknet::Event)]
    struct ExecutorChanged {new_executor:ContractAddress, new_epoch:u32, wlisted:bool}
    #[derive(Drop, starknet::Event)]
    struct ApprovalGranted {#[key] executor:ContractAddress, user:ContractAddress, epoch:u32}
    #[derive(Drop, starknet::Event)]
    struct GlobalEpoch {epoch:u32}

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        OwnerChanged: OwnerChanged,
        ExecutorChanged: ExecutorChanged,
        ApprovalGranted:ApprovalGranted,
        GlobalEpoch: GlobalEpoch
    }
}