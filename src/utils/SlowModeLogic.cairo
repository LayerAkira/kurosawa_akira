use serde::Serde;

#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
struct SlowModeDelay {
    block: u64,
    ts: u64,
}

#[starknet::contract]
mod SlowMode {
    use starknet::ContractAddress;
    use super::SlowModeDelay;
    use kurosawa_akira::utils::common::ChainCtx;

    #[storage]
    struct Storage {
        block_time_of_requested_action: LegacyMap::<u256, (u64, u64)>,
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

    fn remove_if_have_entry(ref self: ContractState, key: u256) {
        self.block_time_of_requested_action.write(key, (0, 0));
    }

    fn update_delay(ref self: ContractState, new_delay: SlowModeDelay, ctx: ChainCtx) {
        assert(self.owner.read() == ctx.caller, 'only_owner');
        assert(new_delay.block <= self.max_delay.read().block, 'wrong_block');
        assert(new_delay.ts <= self.max_delay.read().ts, 'wrong_ts');
        self.delay.write(new_delay);
    }

    fn assert_delay(ref self: ContractState, key: u256, ctx: ChainCtx) {
        let (req_block, req_time) = self.block_time_of_requested_action.read(key);
        assert(
            ctx.timestamp
                - req_time >= self.delay.read().ts && ctx.block
                - req_block >= self.delay.read().block,
            'early invoke'
        );
    }

    fn assert_request_and_apply(
        ref self: ContractState, maker: ContractAddress, key: u256, ctx: ChainCtx
    ) {
        assert(maker == ctx.caller, 'user himself');
        assert(self.block_time_of_requested_action.read(key) == (0, 0), 'aldy rqsted');
        self.block_time_of_requested_action.write(key, (ctx.block, ctx.timestamp));
    }

    fn assert_have_request_and_apply(
        ref self: ContractState, maker: ContractAddress, key: u256, ctx: ChainCtx
    ) {
        assert(maker == ctx.caller, 'user himself');
        assert(self.block_time_of_requested_action.read(key) != (0, 0), 'no cnl req');
        self.block_time_of_requested_action.write(key, (0, 0));
    }
}
