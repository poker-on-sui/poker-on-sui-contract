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
  game::create(coin, scenario.ctx());

  scenario
}

// ===== Player Actions Macros =====

/// Mutates the poker game state as a specific player
public macro fun act_as(
  $scenario: &mut Scenario,
  $player: address,
  $action: |&mut PokerGame|,
) {
  let scenario = $scenario;
  let player = $player;
  scenario.next_tx(player);
  let mut game = scenario.take_shared<PokerGame>();
  $action(&mut game);
  ts::return_shared(game);
}

/// Inspects the poker game state without modifying it
public macro fun inspect_as(
  $scenario: &mut Scenario,
  $player: address,
  $action: |&PokerGame|,
) {
  let scenario = $scenario;
  let player = $player;
  scenario.next_tx(player);
  let game = scenario.take_shared<PokerGame>();
  $action(&game);
  ts::return_shared(game);
}

use fun act_as as ts::Scenario.act_as;
use fun inspect_as as ts::Scenario.inspect_as;

// ===== Player Actions Functions =====

/// Joins a player to the poker game with the required buy-in
public fun join_as(scenario: &mut Scenario, player: address) {
  scenario.act_as!(player, |game| {
    let coin = mint_for_testing<SUI>(game.buy_in(), scenario.ctx());
    game.join(coin, scenario.ctx())
  });
}

/// Starts the poker game with a test seed
public fun start_as(scenario: &mut Scenario, player: address) {
  scenario.act_as!(player, |game| {
    let seed = generate_seed_for_test();
    game.start_game_with_seed_for_testing(seed, scenario.ctx());
  });
}

/// Makes a player fold their hand
public fun fold_as(scenario: &mut Scenario, player: address) {
  scenario.act_as!(player, |game| game.fold(scenario.ctx()));
}

/// Makes a player check their hand (no bet required)
public fun check_as(scenario: &mut Scenario, player: address) {
  scenario.act_as!(player, |game| game.check(scenario.ctx()));
}

/// Makes a player call the current bet
public fun call_as(scenario: &mut Scenario, player: address) {
  scenario.act_as!(player, |game| game.call(scenario.ctx()));
}

/// Makes a player bet or raise a specific amount
public fun raise_as(scenario: &mut Scenario, player: address, amount: u64) {
  scenario.act_as!(player, |game| game.bet_or_raise(amount, scenario.ctx()));
}

/// Withdraws the player's winnings from the game and returns the amount withdrawn
public fun withdraw_as(scenario: &mut Scenario, player: address) {
  scenario.act_as!(player, |game| game.withdraw(scenario.ctx()));
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
