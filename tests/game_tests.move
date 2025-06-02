#[test_only]
module poker::game_tests;

use poker::game;
use poker::tests_utils::{Self, create_and_join_game_as};
use std::debug;
use sui::coin::mint_for_testing;
use sui::sui::SUI;
use sui::test_scenario as ts;
use sui::test_utils::assert_eq;

// ===== Constants =====

// Test addresses
const PLAYER0: address = @0xABCD;
const PLAYER1: address = @0x1111;
const PLAYER2: address = @0x2222;
const PLAYER3: address = @0x3333;
const PLAYER4: address = @0x4444;

// Game configuration constants
const BUY_IN: u64 = 1_000_000_000; // 1 SUI
const MIN_BET: u64 = 50_000_000; // 5% of buy_in

// Error codes from the poker module (only keeping used ones for warnings)
// const EGameInProgress: u64 = 0x0000;
// const EInvalidPlayerCount: u64 = 0x0001;
const EInsufficientBuyIn: u64 = 0x0002;
const EInvalidPlayer: u64 = 0x0004;
const EInvalidAction: u64 = 0x0005;
// const EInvalidBet: u64 = 0x0006;
// const ENotYourTurn: u64 = 0x0007;
const EAlreadyJoined: u64 = 0x0009;
const EInvalidSeed: u64 = 0x000A;
const EInvalidGameState: u64 = 0x000B;
// const EInvalidHandSize: u64 = 0x000C;

// Game states from the poker module
// const STATE_WAITING_FOR_PLAYERS: u8 = 0;
// const STATE_PRE_FLOP: u8 = 2;
// const STATE_FLOP: u8 = 3;
// const STATE_TURN: u8 = 4;
// const STATE_RIVER: u8 = 5;
// const STATE_SHOWDOWN: u8 = 6;
const STATE_GAME_OVER: u8 = 7;

// ===== Alias for Scenario =====

use fun tests_utils::join_as as ts::Scenario.join_as;
use fun tests_utils::start_as as ts::Scenario.start_as;
use fun tests_utils::call_as as ts::Scenario.call_as;
use fun tests_utils::fold_as as ts::Scenario.fold_as;
use fun tests_utils::check_as as ts::Scenario.check_as;
use fun tests_utils::raise_as as ts::Scenario.raise_as;
use fun tests_utils::withdraw_as as ts::Scenario.withdraw_as;
use fun tests_utils::act_as as ts::Scenario.act_as;
use fun tests_utils::inspect_as as ts::Scenario.inspect_as;

// ===== Game tests =====

#[test]
#[expected_failure(abort_code = EInsufficientBuyIn, location = game)]
fun test_join_game_insufficient_buy_in() {
  let mut scenario = create_and_join_game_as(PLAYER0);

  // Player tries to join with insufficient funds
  scenario.act_as!(PLAYER1, |game| {
    let coin = mint_for_testing<SUI>(BUY_IN - 1, scenario.ctx()); // Less than required buy-in
    game.join(coin, scenario.ctx());
  });

  ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = EAlreadyJoined, location = game)]
fun test_join_game_already_joined() {
  let mut g = create_and_join_game_as(PLAYER0);

  // Player 1 joins
  g.join_as(PLAYER1);

  // Player 1 tries to join again
  g.join_as(PLAYER1);

  ts::end(g);
}

#[test]
fun test_start_game() {
  let mut g = create_and_join_game_as(PLAYER0);

  // Add 2 players
  g.join_as(PLAYER1);
  g.join_as(PLAYER2);

  // Total pot should be 3x buy-in
  g.inspect_as!(PLAYER0, |game| assert_eq(game.treasury_balance(), BUY_IN * 3));

  // PLAYER0 starts the game
  g.start_as(PLAYER0);

  ts::end(g);
}

#[test]
#[expected_failure(abort_code = EInvalidPlayer, location = game)]
// EInvalidPlayer from poker module
fun test_start_game_not_owner() {
  let mut scenario = create_and_join_game_as(PLAYER0);

  // Add 2 players
  scenario.join_as(PLAYER1);
  scenario.join_as(PLAYER2);

  // Player1 tries to start the game (not the owner)
  scenario.start_as(PLAYER1);

  ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = EInvalidSeed, location = game)]
fun test_start_game_invalid_seed() {
  let mut scenario = create_and_join_game_as(PLAYER0);

  // Add 2 players
  scenario.join_as(PLAYER1);
  scenario.join_as(PLAYER2);

  // PLAYER0 tries to start game with empty seed
  scenario.act_as!(PLAYER0, |game| {
    game.start_game_with_seed_for_testing(vector[], scenario.ctx());
  });

  ts::end(scenario);
}

#[test]
fun test_player_actions() {
  let mut scenario = create_and_join_game_as(PLAYER0);

  // Add 4 players
  scenario.join_as(PLAYER1);
  scenario.join_as(PLAYER2);
  scenario.join_as(PLAYER3);
  scenario.join_as(PLAYER4);

  // Start the game
  scenario.start_as(PLAYER0);

  // Test player actions - first player after big blind calls
  scenario.call_as(PLAYER3); // Player after big blind (position 3)
  scenario.raise_as(PLAYER4, MIN_BET * 3); // Player 4 raises to triple the minimum bet
  scenario.fold_as(PLAYER0); // Dealer folds
  scenario.fold_as(PLAYER1); // Small blind folds
  scenario.call_as(PLAYER2); // Big blind calls

  ts::end(scenario);
}

#[test]
fun test_full_game_flow() {
  let mut scenario = create_and_join_game_as(PLAYER0);

  // Add 2 players
  scenario.join_as(PLAYER1);
  scenario.join_as(PLAYER2);

  // Start the game
  scenario.start_as(PLAYER0);

  // Pre-flop actions
  scenario.call_as(PLAYER0); // First to act in 3-player (dealer after big blind), call
  scenario.call_as(PLAYER1); // Small blind calls
  scenario.check_as(PLAYER2); // Big blind gets option to check since everyone called

  // Flop actions
  scenario.check_as(PLAYER1); // First player after flop (small blind)
  scenario.check_as(PLAYER2); // Big blind
  scenario.check_as(PLAYER0); // Dealer

  // Turn actions
  scenario.raise_as(PLAYER1, MIN_BET); // First to act (small blind)
  scenario.call_as(PLAYER2); // Big blind
  scenario.call_as(PLAYER0); // Dealer

  // River actions
  scenario.check_as(PLAYER1); // First to act (small blind)
  scenario.check_as(PLAYER2); // Big blind
  scenario.check_as(PLAYER0); // Dealer

  scenario.inspect_as!(PLAYER0, |game| {
    // Check game state after all actions
    assert_eq(game.state(), STATE_GAME_OVER);
    assert_eq(game.treasury_balance(), BUY_IN * 3); // Total pot should be 3x buy-in
    debug::print(game);
    let player0_balance = game.get_player_balance(PLAYER0);
    let player1_balance = game.get_player_balance(PLAYER1);
    let player2_balance = game.get_player_balance(PLAYER2);
    let total_balance = player0_balance + player1_balance + player2_balance;
    assert_eq(total_balance, game.treasury_balance()); // Total balance should match treasury
    assert!(
      player0_balance >= BUY_IN || player1_balance >= BUY_IN || player2_balance >= BUY_IN,
    ); // At least one player should have winnings
    assert_eq(game.side_pots_count(), 0); // No side pots in this simple game
  });

  ts::end(scenario);
}

#[test]
fun test_all_in_scenario() {
  let mut scenario = create_and_join_game_as(PLAYER0);

  // Add 2 players
  scenario.join_as(PLAYER1);
  scenario.join_as(PLAYER2);

  // Start the game
  scenario.start_as(PLAYER0);

  // PLAYER0 goes all-in pre-flop (first to act in 3-player)
  scenario.raise_as(PLAYER0, BUY_IN);
  scenario.call_as(PLAYER1);
  scenario.call_as(PLAYER2);

  // This should automatically advance to showdown
  // TODO: check that the game state is correct after all-in

  ts::end(scenario);
}

#[test]
fun test_four_player_game_flow() {
  let mut scenario = create_and_join_game_as(PLAYER0);

  // Add 4 players
  scenario.join_as(PLAYER1);
  scenario.join_as(PLAYER2);
  scenario.join_as(PLAYER3);
  scenario.join_as(PLAYER4);

  // Start the game
  scenario.start_as(PLAYER0);

  // Pre-flop actions (5 players: PLAYER0=dealer, PLAYER1=small blind, PLAYER2=big blind, PLAYER3=first to act)
  scenario.call_as(PLAYER3); // First player after big blind (position 3)
  scenario.call_as(PLAYER4); // Second to act (position 4)
  scenario.call_as(PLAYER0); // Dealer (position 0)
  scenario.call_as(PLAYER1); // Small blind (position 1)
  scenario.check_as(PLAYER2); // Big blind (position 2)

  // Flop actions (all players check)
  scenario.check_as(PLAYER1); // First to act after flop (position 1)
  scenario.check_as(PLAYER2); // Position 2
  scenario.check_as(PLAYER3); // Position 3
  scenario.check_as(PLAYER4); // Position 4
  scenario.check_as(PLAYER0); // Dealer (position 0)

  // Turn actions
  scenario.raise_as(PLAYER1, MIN_BET); // First to act on turn (position 1)
  scenario.call_as(PLAYER2); // Position 2
  scenario.call_as(PLAYER3); // Position 3
  scenario.call_as(PLAYER4); // Position 4
  scenario.call_as(PLAYER0); // Dealer

  // River actions
  scenario.check_as(PLAYER1); // First to act (small blind)
  scenario.check_as(PLAYER2); // Big blind
  scenario.check_as(PLAYER3); // Position 3
  scenario.check_as(PLAYER4); // Position 4
  scenario.check_as(PLAYER0); // Dealer

  // Game should be over now with PLAYER1, PLAYER3, and PLAYER4 remaining
  // TODO: Verify game state and pot balance

  ts::end(scenario);
}

#[test]
fun test_four_player_all_in_scenario() {
  let mut scenario = create_and_join_game_as(PLAYER0);

  // Add 4 players
  scenario.join_as(PLAYER1);
  scenario.join_as(PLAYER2);
  scenario.join_as(PLAYER3);
  scenario.join_as(PLAYER4);

  // Start the game
  scenario.start_as(PLAYER0);

  // PLAYER3 goes all-in pre-flop (first to act in 5-player game)
  scenario.raise_as(PLAYER3, BUY_IN);
  scenario.call_as(PLAYER4);
  scenario.call_as(PLAYER0);
  scenario.call_as(PLAYER1);
  scenario.call_as(PLAYER2);

  // This should automatically advance to showdown with all players all-in
  // TODO: check that the game state is correct after all-in

  ts::end(scenario);
}

// ===== Hand Evaluation Tests =====

#[test]
fun test_hand_evaluation_integration() {
  let mut scenario = create_and_join_game_as(PLAYER0);

  // Join 2 players to create a simple 3-player game
  scenario.join_as(PLAYER1);
  scenario.join_as(PLAYER2);

  // Start the game to trigger hand evaluation logic
  scenario.start_as(PLAYER0);

  // Have players take actions to reach showdown where hand evaluation occurs
  scenario.call_as(PLAYER0); // Dealer (first to act in 3-player)
  scenario.call_as(PLAYER1); // Small blind
  scenario.check_as(PLAYER2); // Big blind

  // Flop round - have all players check to advance
  scenario.check_as(PLAYER1); // First to act post-flop
  scenario.check_as(PLAYER2);
  scenario.check_as(PLAYER0);

  // Turn round - have all players check to advance
  scenario.check_as(PLAYER1);
  scenario.check_as(PLAYER2);
  scenario.check_as(PLAYER0);

  // River round - have all players check to trigger showdown and hand evaluation
  scenario.check_as(PLAYER1);
  scenario.check_as(PLAYER2);
  scenario.check_as(PLAYER0);

  // The game should now be completed with hand evaluation having determined the winner
  // This test ensures the hand evaluation system integrates properly without errors
  // TODO: Verify the winner and hand rankings if needed

  ts::end(scenario);
}

#[test]
fun test_side_pot_all_in_scenario() {
  let mut scenario = create_and_join_game_as(PLAYER0);

  // Add 2 players
  scenario.join_as(PLAYER1);
  scenario.join_as(PLAYER2);

  // Start the game
  scenario.start_as(PLAYER0);

  // PLAYER0 goes all-in pre-flop (first to act in 3-player)
  scenario.raise_as(PLAYER0, BUY_IN); // Raise to all-in
  scenario.call_as(PLAYER1); // Player1 calls
  scenario.call_as(PLAYER2); // Player2 calls

  // This should automatically advance to showdown
  // TODO: check that side pot logic is correctly handled

  ts::end(scenario);
}

#[test]
fun test_side_pot_multiple_all_ins() {
  let mut scenario = create_and_join_game_as(PLAYER0);

  // Add more players for complex side pot scenario
  scenario.join_as(PLAYER1);
  scenario.join_as(PLAYER2);
  scenario.join_as(PLAYER3);

  // Start the game
  scenario.start_as(PLAYER0);

  // Create scenario with different all-in amounts
  // Pre-flop: PLAYER0 (dealer), PLAYER1 (SB), PLAYER2 (BB), PLAYER3 first to act

  // PLAYER3 raises significantly
  scenario.raise_as(PLAYER3, MIN_BET * 4); // Raise to 4x min bet
  scenario.call_as(PLAYER0);
  scenario.call_as(PLAYER1);
  scenario.call_as(PLAYER2); // PLAYER2 calls to complete pre-flop

  // Now in post-flop, create different all-in amounts to test side pots
  // Test scenario: Have players bet/call different amounts to go all-in

  // PLAYER1 (first to act post-flop) bets a smaller amount
  {
    // Bet half of remaining balance to leave room for raises
    let remaining_balance = BUY_IN - MIN_BET * 4;
    let bet_amount = remaining_balance / 2;
    scenario.raise_as(PLAYER1, bet_amount);
  };

  // PLAYER2 raises to a larger amount
  {
    // Raise to 3/4 of remaining balance
    let remaining_balance = BUY_IN - MIN_BET * 4;
    let raise_amount = (remaining_balance * 3) / 4;
    scenario.raise_as(PLAYER2, raise_amount);
  };

  // PLAYER3 goes all-in
  {
    // Go all-in with all remaining balance
    let remaining_balance = BUY_IN - MIN_BET * 4;
    scenario.raise_as(PLAYER3, remaining_balance);
  };

  // PLAYER0 calls to see the action through to showdown
  scenario.call_as(PLAYER0);

  // Verify the game handled multiple all-ins correctly by checking game state
  // The game should automatically proceed through remaining streets and showdown
  // Multiple side pots should be created based on different all-in amounts
  scenario.inspect_as!(PLAYER0, |_game| {});

  // At this point, the game should have created multiple side pots:
  // - Main pot: Available to all players (up to PLAYER1's all-in amount)
  // - Side pot 1: Available to PLAYER2, PLAYER3, PLAYER0 (up to PLAYER3's amount)
  // - Side pot 2: Available to PLAYER2 and PLAYER0 (remaining amount)

  // The game will automatically proceed through remaining betting rounds and showdown
  // TODO: Testing that the side pot logic handles complex multi-player scenarios correctly

  ts::end(scenario);
}

#[test]
fun test_dealer_rotation_multiple_hands() {
  let mut scenario = create_and_join_game_as(PLAYER0);

  // Add players
  scenario.join_as(PLAYER1);
  scenario.join_as(PLAYER2);

  // Start first hand - PLAYER0 is dealer (position 0)
  scenario.start_as(PLAYER0);

  // Fast forward to game over state for first hand
  scenario.fold_as(PLAYER0);
  scenario.fold_as(PLAYER1);

  // PLAYER2 wins by default (only one left)
  // Game should now be in STATE_GAME_OVER

  // Start new hand with rotated dealer - should be PLAYER1 (position 1)
  scenario.start_as(PLAYER0);

  // Verify dealer has rotated by checking blind positions
  // In second hand: PLAYER1 is dealer, PLAYER2 is small blind, PLAYER0 is big blind
  // We can verify this by checking who needs to post blinds and act first
  scenario.inspect_as!(PLAYER0, |game| {
    assert_eq(game.dealer_position(), 1);
  });

  // Fast forward second hand to test third hand rotation
  // In second hand: PLAYER1 is dealer, PLAYER2 is SB, PLAYER0 is BB
  // First to act pre-flop is PLAYER1 (dealer acts first in 3-player when big blind is posted)
  scenario.fold_as(PLAYER1);
  scenario.fold_as(PLAYER2);

  // Start third hand - dealer should now be PLAYER2 (position 2)
  scenario.start_as(PLAYER0);

  ts::end(scenario);
}

// ===== Withdraw Function Tests =====

#[test]
fun test_successful_withdraw() {
  let mut scenario = create_and_join_game_as(PLAYER0);

  // Add players
  scenario.join_as(PLAYER1);
  scenario.join_as(PLAYER2);

  // Start the game
  scenario.start_as(PLAYER0);

  // Play a simple game to completion - PLAYER1 and PLAYER2 fold, PLAYER0 wins
  scenario.call_as(PLAYER0); // First to act (dealer in 3-player)
  scenario.fold_as(PLAYER1); // Small blind
  scenario.fold_as(PLAYER2); // Big blind

  // Test successful withdrawal by winner
  scenario.withdraw_as(PLAYER0);

  ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = EInvalidGameState)]
fun test_withdraw_game_not_over() {
  let mut scenario = create_and_join_game_as(PLAYER0);

  // Add one player
  scenario.join_as(PLAYER1);

  // Try to withdraw before game starts (should fail)
  scenario.withdraw_as(PLAYER0);

  ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = EInvalidPlayer)]
fun test_withdraw_invalid_player() {
  let mut scenario = create_and_join_game_as(PLAYER0);

  // Add players and complete a game
  scenario.join_as(PLAYER1);

  scenario.join_as(PLAYER2);

  // Start and complete the game
  scenario.start_as(PLAYER0);

  // Complete game quickly - players fold
  scenario.call_as(PLAYER0);

  scenario.fold_as(PLAYER1);

  scenario.fold_as(PLAYER2);

  // Try to withdraw with player not in game (should fail)
  scenario.withdraw_as(PLAYER3); // Player who didn't join the game

  ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = EInvalidAction)]
fun test_withdraw_no_winnings() {
  let mut scenario = create_and_join_game_as(PLAYER0);

  // Add players
  scenario.join_as(PLAYER1);
  scenario.join_as(PLAYER2);

  // Start and complete the game
  scenario.start_as(PLAYER0);

  // Complete game - PLAYER0 wins, others lose
  scenario.raise_as(PLAYER0, BUY_IN); // PLAYER0 goes all-in
  scenario.call_as(PLAYER1);
  scenario.fold_as(PLAYER2);

  // Since all players is now all-in, game should ended with PLAYER0 OR PLAYER01 winning
  scenario.inspect_as!(PLAYER0, |game| {
    assert_eq(game.state(), STATE_GAME_OVER);
  });

  // Try to withdraw with losing player (should fail)
  scenario.withdraw_as(PLAYER1); // Player who folded and has no winnings

  ts::end(scenario);
}

#[test]
fun test_multiple_player_withdraw() {
  let mut scenario = create_and_join_game_as(PLAYER0);

  // Add players
  scenario.join_as(PLAYER1);
  scenario.join_as(PLAYER2);

  // Start the game
  scenario.start_as(PLAYER0);

  // Play to showdown where multiple players might have winnings
  // When game started, PLAYER0 was dealer, PLAYER1 small blind, PLAYER2 big blind
  // Player 0 is first to act pre-flop
  scenario.call_as(PLAYER0); // Dealer calls
  scenario.call_as(PLAYER1); // Small blind calls
  scenario.check_as(PLAYER2); // Big blind checks

  // Continue through all rounds to showdown
  // Flop
  scenario.check_as(PLAYER1);
  scenario.check_as(PLAYER2);
  scenario.check_as(PLAYER0);

  // Turn
  scenario.check_as(PLAYER1);
  scenario.check_as(PLAYER2);
  scenario.check_as(PLAYER0);

  // River - this will trigger showdown
  scenario.check_as(PLAYER1);
  scenario.fold_as(PLAYER2);
  scenario.fold_as(PLAYER0);

  // Now test that winner(s) can withdraw their winnings
  // Try withdrawing with all players - only winner(s) should succeed
  scenario.withdraw_as(PLAYER0);

  ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = EInvalidAction)]
fun test_withdraw_twice() {
  let mut scenario = create_and_join_game_as(PLAYER0);

  // Add one player
  scenario.join_as(PLAYER1);

  // Start the game
  scenario.start_as(PLAYER0);

  // Complete game - PLAYER1 folds, PLAYER0 wins
  scenario.fold_as(PLAYER1);

  // First withdrawal (should succeed)
  scenario.withdraw_as(PLAYER0);

  // Second withdrawal attempt (should fail with EInvalidAction)
  scenario.withdraw_as(PLAYER0);

  ts::end(scenario);
}
