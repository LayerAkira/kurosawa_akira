use serde::Serde;

#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
struct SlowModeDelay {
    block: u64,
    ts: u64,
}

use starknet::ContractAddress;
#[starknet::interface]
trait ISlowMode<TContractState> {
    fn remove_if_have_entry(ref self: TContractState, key: felt252);

    fn update_delay(ref self: TContractState, new_delay: SlowModeDelay);

    fn assert_delay(ref self: TContractState, key: felt252);

    fn assert_request_and_apply(ref self: TContractState, maker: ContractAddress, key: felt252);

    fn assert_have_request_and_apply(
        ref self: TContractState, maker: ContractAddress, key: felt252
    );
}

#[starknet::contract]
mod SlowMode {
    use starknet::ContractAddress;
    use super::SlowModeDelay;
    use starknet::get_caller_address;
    use starknet::info::get_block_timestamp;
    use starknet::info::get_block_number;

    #[storage]
    struct Storage {
        block_time_of_requested_action: LegacyMap::<felt252, (u64, u64)>,
        delay: SlowModeDelay,
        max_delay: SlowModeDelay,
        owner: ContractAddress,
    }


    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress, delay: SlowModeDelay) {
        self.owner.write(owner);
        self.delay.write(delay);
        self.max_delay.write(delay);
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {}

    #[external(v0)]
    fn remove_if_have_entry(ref self: ContractState, key: felt252) {
        self.block_time_of_requested_action.write(key, (0, 0));
    }

    #[external(v0)]
    fn update_delay(ref self: ContractState, new_delay: SlowModeDelay) {
        let caller = get_caller_address();
        assert(self.owner.read() == caller, 'only_owner');
        assert(new_delay.block <= self.max_delay.read().block, 'wrong_block');
        assert(new_delay.ts <= self.max_delay.read().ts, 'wrong_ts');
        self.delay.write(new_delay);
    }

    #[external(v0)]
    fn assert_delay(ref self: ContractState, key: felt252) {
        let (req_block, req_time) = self.block_time_of_requested_action.read(key);
        let timestamp = get_block_timestamp();
        let block = get_block_number();
        assert(
            timestamp
                - req_time >= self.delay.read().ts && block
                - req_block >= self.delay.read().block,
            'early invoke'
        );
    }

    #[external(v0)]
    fn assert_request_and_apply(ref self: ContractState, maker: ContractAddress, key: felt252) {
        let caller = get_caller_address();
        assert(maker == caller, 'user himself');
        assert(self.block_time_of_requested_action.read(key) == (0, 0), 'aldy rqsted');
        let timestamp = get_block_timestamp();
        let block = get_block_number();
        self.block_time_of_requested_action.write(key, (block, timestamp));
    }

    #[external(v0)]
    fn assert_have_request_and_apply(
        ref self: ContractState, maker: ContractAddress, key: felt252
    ) {
        let caller = get_caller_address();
        assert(maker == caller, 'user himself');
        assert(self.block_time_of_requested_action.read(key) != (0, 0), 'no cnl req');
        self.block_time_of_requested_action.write(key, (0, 0));
    }
}
