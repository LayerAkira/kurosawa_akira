

#[starknet::contract]
mod HashVerifierByApproval {
    use starknet::ContractAddress;
    use starknet::{get_block_timestamp, get_caller_address};
    use kurosawa_akira::SignerComponent::{check_sign, SignatureVerifier};



    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        HashApproved: HashApproved,
        HashInvalidated: HashInvalidated,
        ExchangeSignerMutated:ExchangeSignerMutated,
        CancelDelaySecMutated:CancelDelaySecMutated,
    }

    #[derive(Drop, starknet::Event)]
    struct HashApproved {
        #[key] trader:  ContractAddress,
        #[key] hash:    felt252,
        core_address: ContractAddress,
        expire_at:      u64,
    }

    #[derive(Drop, starknet::Event)]
    struct HashInvalidated {
        #[key] trader:  ContractAddress,
        #[key] hash:    felt252,
        core_address: ContractAddress,
        expire_at:      u64,
    }

    #[derive(Drop, starknet::Event)]
    struct ExchangeSignerMutated {
        #[key] signer:  ContractAddress,
        is_set: bool,
    }
    #[derive(Drop, starknet::Event)]
    struct CancelDelaySecMutated {
       cancel_delay_sec:u8
    }



    #[storage]
    struct Storage {
        /// (trader, core_address, hash) → expiry-timestamp (0 = never approved, ≤ now = invalid)
        approvals: starknet::storage::Map::<(ContractAddress, ContractAddress, felt252), u64>,
        is_exchange_signer: starknet::storage::Map::<ContractAddress, bool>,
        owner: ContractAddress,
        cancel_delay_sec:u8
    }

    #[constructor]
    fn constructor(ref self: ContractState, owner:ContractAddress) {
        self.owner.write(owner);
    }

    #[external(v0)]
    fn set_exchange_signer(ref self: ContractState, signer:ContractAddress, is_set:bool) {
        assert(get_caller_address() == self.owner.read(), 'ONLY_OWNER');
        self.is_exchange_signer.write(signer, is_set);
        self.emit(ExchangeSignerMutated{signer, is_set});
    }

    #[external(v0)]
    fn set_cancel_delay_sec(ref self: ContractState, cancel_delay_sec:u8) {
        assert(get_caller_address() == self.owner.read(), 'ONLY_OWNER');
        self.cancel_delay_sec.write(cancel_delay_sec);
        self.emit(CancelDelaySecMutated{cancel_delay_sec});
    }


    #[external(v0)]
    fn is_exchange_signer(self: @ContractState, signer:ContractAddress) -> bool { self.is_exchange_signer.read(signer)}
    
    #[external(v0)]
    fn expire_at(self: @ContractState, trader:ContractAddress, coreAddress:ContractAddress, hash:felt252 ) -> u64 { 
        self.approvals.read((trader,coreAddress,hash))}
    

    /// Public helper – pre-approve an order hash until `expire_at`.
    /// Must be called *by* the trading account itself.
    #[external(v0)]
    fn approve_signature(ref self: ContractState, hash: felt252, expire_at: u64, core_address: ContractAddress) {
        let trader = get_caller_address();
        let now = get_block_timestamp();

        assert(expire_at.into() > now, 'EXPIRATION_IN_PAST');
        assert(hash != 0, 'ZERO_HASH');
        assert(self.approvals.read((trader, core_address, hash)) == 0, 'ALREADY APPROVED');
        self.approvals.write((trader, core_address, hash), expire_at);
        self.emit(HashApproved{ trader, hash, core_address, expire_at });
    }

    #[external(v0)]
    fn invalidate_signature(ref self: ContractState, hash: felt252, core_address:ContractAddress,  exchange_account:ContractAddress,  exchange_signature: Span<felt252>) {
        let trader = get_caller_address();
        let now    = get_block_timestamp();
        let current = self.approvals.read((trader, core_address, hash));
        assert(current > now, 'NOT_ACTIVE');
        
        let mut expire_at = 0;
        // Slow path: user-requested delay
        if (exchange_signature.len() == 0) {
            expire_at = now + self.cancel_delay_sec.read().into();
        } else {
            assert(self.is_exchange_signer.read(exchange_account), 'NOT EXCHANGE SIGNER');
            assert(check_sign(exchange_account, hash, exchange_signature), 'INVALID EXCHANGE SIGN');
        }
        self.approvals.write((trader, core_address, hash), if (expire_at > current) {current} else {expire_at});
        self.emit(HashInvalidated{trader, hash, expire_at, core_address});
    }

    #[abi(embed_v0)]
    impl SignatureVerifierImpl of SignatureVerifier<ContractState> {
        /// Called from SignerLogic.verify().
        fn verify(self: @ContractState, signer: felt252, message: felt252, signature: Span<felt252>, account: ContractAddress) -> bool {
            let core_address  = get_caller_address();
            let expire_at = self.approvals.read((account, core_address, message));
            let now = get_block_timestamp();
            return expire_at > now;
        }

        fn alias(self: @ContractState) -> felt252 { 'hash_approve'}
    }
}
