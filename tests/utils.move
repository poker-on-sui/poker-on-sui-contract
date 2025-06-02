#[test_only]
module poker::tests_utils;

use poker::game::{Self, PokerGame};
use sui::coin::mint_for_testing;
use sui::random::new_generator_for_testing;
use sui::sui::SUI;
use sui::test_scenario::{Self as ts, Scenario};

// Game configuration constants
const BUY_IN: u64 = 1_000_000_000; // 1 SUI
const SEED_LENGTH: u64 = 32;

/// Creates a new poker game and returns a test scenario with the creator automatically joined
public fun create_and_join_game_as(player: address): Scenario {
  let mut scenario = ts::begin(player);

  // Create the poker game with creator automatically joining
  let coin = mint_for_testing<SUI>(BUY_IN, scenario.ctx());
  game::create_game(coin, scenario.ctx());

  scenario
}

// ===== Player Actions Functions =====
// Should always advance the scenario to the next transaction with player_X

/// Joins a player to the poker game with the required buy-in
public fun join_as(scenario: &mut Scenario, player: address) {
  scenario.next_tx(player);
  let mut game = scenario.take_shared<PokerGame>();
  let coin = mint_for_testing<SUI>(game.buy_in(), scenario.ctx());
  game.join_game(coin, scenario.ctx());
  ts::return_shared(game);
}

/// Starts the poker game with a test seed
public fun start_as(scenario: &mut Scenario, player: address) {
  scenario.next_tx(player);
  let mut game = scenario.take_shared<PokerGame>();
  let seed = generate_seed_for_test();
  game.start_game_with_seed_for_testing(seed, scenario.ctx());
  ts::return_shared(game);
}

/// Makes a player fold their hand
public fun fold_as(scenario: &mut Scenario, player: address) {
  scenario.next_tx(player);
  let mut game = scenario.take_shared<PokerGame>();
  game.fold(scenario.ctx());
  ts::return_shared(game);
}

/// Makes a player check their hand (no bet required)
public fun check_as(scenario: &mut Scenario, player: address) {
  scenario.next_tx(player);
  let mut game = scenario.take_shared<PokerGame>();
  game.check(scenario.ctx());
  ts::return_shared(game);
}

/// Makes a player call the current bet
public fun call_as(scenario: &mut Scenario, player: address) {
  scenario.next_tx(player);
  let mut game = scenario.take_shared<PokerGame>();
  game.call(scenario.ctx());
  ts::return_shared(game);
}

/// Makes a player bet a specific amount
public fun bet_as(scenario: &mut Scenario, player: address, amount: u64) {
  scenario.next_tx(player);
  let mut game = scenario.take_shared<PokerGame>();
  game.bet(amount, scenario.ctx());
  ts::return_shared(game);
}

/// Makes a player raise the current bet by a specific amount
public fun raise_as(scenario: &mut Scenario, player: address, amount: u64) {
  scenario.next_tx(player);
  let mut game = scenario.take_shared<PokerGame>();
  game.raise(amount, scenario.ctx());
  ts::return_shared(game);
}

/// Withdraws the player's winnings from the game and returns the amount withdrawn
public fun withdraw_as(scenario: &mut Scenario, player: address) {
  scenario.next_tx(player);
  let mut game = scenario.take_shared<PokerGame>();
  game.withdraw(scenario.ctx());
  ts::return_shared(game);
}

/// Rotate dealer position and reset for new hand
public fun start_new_hand_as(scenario: &mut Scenario, player: address) {
  scenario.next_tx(player);
  let mut game = scenario.take_shared<PokerGame>();
  game.start_new_hand(scenario.ctx());
  ts::return_shared(game);
}

// ===== Game helper Functions =====

public fun check_game_state_as(scenario: &mut Scenario, player: address): u8 {
  scenario.next_tx(player);
  let game = scenario.take_shared<PokerGame>();
  let state = game.state();
  ts::return_shared(game);
  state
}

// ===== Other Helper Functions =====

/// Generates a random seed for testing purposes
public fun generate_seed_for_test(): vector<u8> {
  let mut generator = new_generator_for_testing();
  let mut seed = vector::empty<u8>();
  let mut i = 0;
  while (i < SEED_LENGTH) {
    let byte = generator.generate_u8();
    seed.push_back(byte);
    i = i + 1;
  };
  seed
}
