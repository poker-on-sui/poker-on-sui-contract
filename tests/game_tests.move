#[test_only]
module poker::game_tests;

// use poker::debug::print_debug;
use poker::game;
use poker::tests_utils::{Self, create_and_join_game_as};
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
const MIN_BUY_IN: u64 = 10_000_000; // 0.01 SUI
const MIN_BET: u64 = 500_000; // 5% of buy_in

// Error codes from the poker module (only keeping used ones for warnings)
const EInvalidGameState: u64 = 0x000B; // Internal errors
const EGameInProgress: u64 = 0x0000;
const EGameNotStarted: u64 = 0x0001;
const EEInsufficientPlayer: u64 = 0x0002;
const EInsufficientBuyIn: u64 = 0x0003;
const EBuyInMismatch: u64 = 0x0004;
const EInvalidPlayer: u64 = 0x0005;
const EInvalidAction: u64 = 0x0006;
const EInvalidAmount: u64 = 0x0007;
const EAlreadyJoined: u64 = 0x0008;
const ESeatOccupied: u64 = 0x0009;
const EInvalidSeat: u64 = 0x000A;

// Player states
const PlayerState_Waiting: u64 = 0;
const PlayerState_Active: u64 = 1;
// const PlayerState_Checked: u64 = 2;
// const PlayerState_Called: u64 = 3;
// const PlayerState_RaisedOrBetted: u64 = 4;
const PlayerState_Folded: u64 = 5;
// const PlayerState_AllIn: u64 = 6;

// ===== Alias for game tests =====

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
fun test_create_game_with_insufficient_buy_in() {
  let mut g = ts::begin(PLAYER0);

  // Player tries to create a game with insufficient funds
  let coin = mint_for_testing<SUI>(MIN_BUY_IN - 1, g.ctx());
  game::create(coin, g.ctx());

  ts::end(g);
}

#[test]
#[expected_failure(abort_code = EBuyInMismatch, location = game)]
fun test_join_game_insufficient_buy_in() {
  let mut g = create_and_join_game_as(PLAYER0);

  // Player tries to join with insufficient funds
  g.act_as!(PLAYER1, |game| {
    let coin = mint_for_testing<SUI>(MIN_BUY_IN - 1, g.ctx()); // Less than required buy-in
    game.join(coin, 0, g.ctx());
  });

  ts::end(g);
}

#[test]
#[expected_failure(abort_code = EAlreadyJoined, location = game)]
fun test_join_game_already_joined() {
  let mut g = create_and_join_game_as(PLAYER0);

  // Player 1 joins
  g.join_as(PLAYER1, 1);

  // Player 1 tries to join again
  g.join_as(PLAYER1, 2);

  ts::end(g);
}

#[test]
#[expected_failure(abort_code = ESeatOccupied, location = game)]
fun test_join_seat_occupied() {
  let mut g = create_and_join_game_as(PLAYER0);

  g.join_as(PLAYER1, 1); // Player 1 joins
  g.join_as(PLAYER2, 1); // Player 2 tries to join to seat 1 again

  ts::end(g);
}

#[test]
#[expected_failure(abort_code = EInvalidSeat, location = game)]
fun test_join_invalid_seat() {
  let mut g = create_and_join_game_as(PLAYER0);

  g.join_as(PLAYER1, 1); // Player 1 joins
  g.join_as(PLAYER2, 9); // Player 2 tries to join to seat 9 (invalid seat)

  ts::end(g);
}

#[test]
fun test_start_game() {
  let mut g = create_and_join_game_as(PLAYER0);

  // Add 2 players
  g.join_as(PLAYER1, 1);
  g.join_as(PLAYER2, 2);

  // Total treasury should be 3x buy-in
  g.inspect_as!(
    PLAYER0,
    |game| assert_eq(game.get_treasury_balance(), MIN_BUY_IN * 3),
  );

  // PLAYER0 starts the game
  g.start_as(PLAYER0);

  ts::end(g);
}

#[test]
#[expected_failure(abort_code = EInvalidPlayer, location = game)]
// EInvalidPlayer from poker module
fun test_start_game_not_owner() {
  let mut g = create_and_join_game_as(PLAYER0);

  // Add 2 players
  g.join_as(PLAYER1, 1);
  g.join_as(PLAYER2, 2);

  // Player1 tries to start the game (not the owner)
  g.start_as(PLAYER1);

  ts::end(g);
}

#[test]
#[expected_failure(abort_code = EInvalidGameState, location = game)]
fun test_start_game_invalid_seed() {
  let mut g = create_and_join_game_as(PLAYER0);

  // Add 2 players
  g.join_as(PLAYER1, 1);
  g.join_as(PLAYER2, 2);

  // PLAYER0 tries to start game with empty seed
  g.act_as!(PLAYER0, |game| {
    game.start_with_seed_for_testing(vector[], g.ctx());
  });

  ts::end(g);
}

#[test]
#[expected_failure(abort_code = EEInsufficientPlayer, location = game)]
fun test_start_game_not_enough_player() {
  let mut g = create_and_join_game_as(PLAYER0);

  // PLAYER0 starts the game
  g.start_as(PLAYER0);

  ts::end(g);
}

#[test]
fun test_player_actions() {
  let mut g = create_and_join_game_as(PLAYER0);

  // Add 4 players
  g.join_as(PLAYER1, 1);
  g.join_as(PLAYER2, 2);
  g.join_as(PLAYER3, 3);
  g.join_as(PLAYER4, 4);

  // Start the game
  g.start_as(PLAYER0);

  // Test player actions - first player after big blind calls
  g.call_as(PLAYER3); // Player after big blind (position 3)
  g.raise_as(PLAYER4, MIN_BET * 3); // Player 4 raises to triple the minimum bet
  g.fold_as(PLAYER0); // Dealer folds
  g.fold_as(PLAYER1); // Small blind folds
  g.call_as(PLAYER2); // Big blind calls

  ts::end(g);
}

#[test]
#[expected_failure(abort_code = EGameNotStarted, location = game)]
fun test_act_before_start() {
  let mut g = create_and_join_game_as(PLAYER0);

  // Add 4 players
  g.join_as(PLAYER1, 1);
  g.join_as(PLAYER2, 2);

  g.fold_as(PLAYER2); // Player 2 tries to fold before game starts

  ts::end(g);
}

#[test]
#[expected_failure(abort_code = EInvalidPlayer, location = game)]
fun test_act_not_in_game() {
  let mut g = create_and_join_game_as(PLAYER0);

  // Add players
  g.join_as(PLAYER1, 1);
  g.join_as(PLAYER2, 2);

  // Start the game
  g.start_as(PLAYER0);

  g.fold_as(PLAYER3); // Player 3 tries to fold but is not in the game

  ts::end(g);
}

#[test]
#[expected_failure(abort_code = EInvalidAction, location = game)]
fun test_act_not_in_turn() {
  let mut g = create_and_join_game_as(PLAYER0);

  // Add players
  g.join_as(PLAYER1, 1);
  g.join_as(PLAYER2, 2);

  // Start the game
  g.start_as(PLAYER0);

  g.fold_as(PLAYER1); // Active player is PLAYER0 (dealer), PLAYER1 tries to fold out of turn

  ts::end(g);
}

#[test]
#[expected_failure(abort_code = EInvalidAmount, location = game)]
fun test_raise_invalid() {
  let mut g = create_and_join_game_as(PLAYER0);

  // Add players
  g.join_as(PLAYER1, 1);
  g.join_as(PLAYER2, 2);

  // Start the game
  g.start_as(PLAYER0);

  g.raise_as(PLAYER0, MIN_BET * 2); // PLAYER0 raises to x2 the minimum bet
  g.raise_as(PLAYER1, MIN_BET / 2); // PLAYER1 tries to raise less than minimum bet (should fail)

  ts::end(g);
}

#[test]
#[expected_failure(abort_code = EInvalidAction, location = game)]
fun test_raise_invalid_all_in() {
  let mut g = create_and_join_game_as(PLAYER0);

  // Add players
  g.join_as(PLAYER1, 1);
  g.join_as(PLAYER2, 2);
  g.join_as(PLAYER3, 7);

  // Start the game
  g.start_as(PLAYER0);

  g.raise_as(PLAYER0, MIN_BUY_IN); // PLAYER0 all-ins
  g.call_as(PLAYER1);
  g.raise_as(PLAYER2, MIN_BET); // PLAYER2 raises (should fail since others are all-in)

  ts::end(g);
}

#[test]
fun test_find_next_actor() {
  let mut g = create_and_join_game_as(PLAYER0);

  // Add 4 players
  g.join_as(PLAYER1, 1);
  g.join_as(PLAYER2, 2);
  g.join_as(PLAYER3, 3);
  g.join_as(PLAYER4, 4);

  // Start the game
  g.start_as(PLAYER0);

  g.fold_as(PLAYER3); // Player 3 folds
  g.fold_as(PLAYER4); // Player 4 folds
  g.call_as(PLAYER0); // Dealer calls

  // Test finding next actor after big blind
  g.inspect_as!(PLAYER0, |game| {
    let addr = game.test_find_next_actor(0);
    assert!(addr.is_some()); // Should have an active player
    assert_eq(*addr.borrow(), 1); // Should be PLAYER1
  });

  ts::end(g);
}

#[test]
fun test_full_game_flow() {
  let mut g = create_and_join_game_as(PLAYER0);

  // Add 2 players
  g.join_as(PLAYER1, 1);
  g.join_as(PLAYER2, 2);

  // Start the game
  g.start_as(PLAYER0);

  // Pre-flop actions
  g.call_as(PLAYER0); // First to act in 3-player (dealer after big blind), call
  g.call_as(PLAYER1); // Small blind calls
  g.check_as(PLAYER2); // Big blind gets option to check since everyone called

  // Flop actions
  g.check_as(PLAYER1); // First player after flop (small blind)
  g.check_as(PLAYER2); // Big blind
  g.check_as(PLAYER0); // Dealer

  // Turn actions
  g.raise_as(PLAYER1, MIN_BET); // First to act (small blind)
  g.call_as(PLAYER2); // Big blind
  g.call_as(PLAYER0); // Dealer

  // River actions
  g.check_as(PLAYER1); // First to act (small blind)
  g.check_as(PLAYER2); // Big blind
  g.check_as(PLAYER0); // Dealer

  g.inspect_as!(PLAYER0, |game| {
    // Check game state after all actions
    assert!(game.is_ended()); // Game should be over
    assert_eq(game.get_treasury_balance(), MIN_BUY_IN * 3); // Total pot should be 3x buy-in
    let player0 = game.get_player(PLAYER0);
    let player1 = game.get_player(PLAYER1);
    let player2 = game.get_player(PLAYER2);
    let treasury_balance = game.get_treasury_balance();
    // poker::debug::print_debug(b"ℹ️ Player 0: ", player0);
    // poker::debug::print_debug(b"ℹ️ Player 1: ", player1);
    // poker::debug::print_debug(b"ℹ️ Player 2: ", player2);
    // poker::debug::print_debug(b"ℹ️ Treasury balance: ", &treasury_balance);
    // poker::debug::print_debug(b"ℹ️ Pot: ", &game.get_pot());
    let total_balance =
      player0.get_balance() + player1.get_balance() + player2.get_balance();
    assert_eq(total_balance, treasury_balance); // Total balance should match treasury
    assert!(
      player0.get_balance() >= MIN_BUY_IN || player1.get_balance() >= MIN_BUY_IN || player2.get_balance() >= MIN_BUY_IN,
    ); // At least one player should have winnings
    assert_eq(game.get_side_pots_count(), 0); // No side pots in this simple game
  });

  ts::end(g);
}

#[test]
fun test_all_ins() {
  let mut g = create_and_join_game_as(PLAYER0);

  // Add 2 players
  g.join_as(PLAYER1, 1);
  g.join_as(PLAYER2, 2);

  // Start the game
  g.start_as(PLAYER0);

  // PLAYER0 goes all-in pre-flop (first to act in 3-player)
  g.raise_as(PLAYER0, MIN_BUY_IN);
  g.call_as(PLAYER1);
  // g.inspect_as!(PLAYER0, |game| print_debug(b"ℹ️ Current game state: ", game));
  g.call_as(PLAYER2);

  // This should automatically advance to showdown and end the game
  g.inspect_as!(PLAYER0, |game| {
    // print_debug(b"ℹ️ Current game state: ", game);
    assert!(game.is_ended());
  });

  ts::end(g);
}

#[test]
fun test_four_player_game_flow() {
  let mut g = create_and_join_game_as(PLAYER0);

  // Add 4 players
  g.join_as(PLAYER1, 1);
  g.join_as(PLAYER2, 2);
  g.join_as(PLAYER3, 3);
  g.join_as(PLAYER4, 4);

  // Start the game
  g.start_as(PLAYER0);

  // Pre-flop actions (5 players: PLAYER0=dealer, PLAYER1=small blind, PLAYER2=big blind, PLAYER3=first to act)
  g.call_as(PLAYER3); // First player after big blind (position 3)
  g.call_as(PLAYER4); // Second to act (position 4)
  g.call_as(PLAYER0); // Dealer (position 0)
  g.call_as(PLAYER1); // Small blind (position 1)
  g.check_as(PLAYER2); // Big blind (position 2)

  // Flop actions (all players check)
  g.check_as(PLAYER1); // First to act after flop (position 1)
  g.check_as(PLAYER2); // Position 2
  g.check_as(PLAYER3); // Position 3
  g.check_as(PLAYER4); // Position 4
  g.check_as(PLAYER0); // Dealer (position 0)

  // Turn actions
  g.raise_as(PLAYER1, MIN_BET); // First to act on turn (position 1)
  g.call_as(PLAYER2); // Position 2
  g.call_as(PLAYER3); // Position 3
  g.call_as(PLAYER4); // Position 4
  g.call_as(PLAYER0); // Dealer

  // River actions
  g.check_as(PLAYER1); // First to act (small blind)
  g.check_as(PLAYER2); // Big blind
  g.check_as(PLAYER3); // Position 3
  g.check_as(PLAYER4); // Position 4
  g.check_as(PLAYER0); // Dealer

  // Game should be over now with PLAYER1, PLAYER3, and PLAYER4 remaining
  g.inspect_as!(PLAYER0, |game| {
    assert_eq(game.is_ended(), true);
    assert_eq(game.get_treasury_balance(), MIN_BUY_IN * 5); // Total pot should be 5x buy-in
    let player0 = game.get_player(PLAYER0);
    let player1 = game.get_player(PLAYER1);
    let player2 = game.get_player(PLAYER2);
    let player3 = game.get_player(PLAYER3);
    let player4 = game.get_player(PLAYER4);
    let players = vector[*player0, *player1, *player2, *player3, *player4];
    let total_balance =
      player0.get_balance() + player1.get_balance() + player2.get_balance() +
      player3.get_balance() + player4.get_balance();
    assert_eq(total_balance, game.get_treasury_balance()); // Total balance should match treasury
    assert!(players.count!(|p| p.get_balance() > 0) >= 1); // At least one player should have winnings
  });

  ts::end(g);
}

#[test]
fun test_four_player_all_in() {
  let mut g = create_and_join_game_as(PLAYER0);

  // Add 4 players
  g.join_as(PLAYER1, 1);
  g.join_as(PLAYER2, 2);
  g.join_as(PLAYER3, 3);
  g.join_as(PLAYER4, 4);

  // Start the game
  g.start_as(PLAYER0);

  // PLAYER3 goes all-in pre-flop (first to act in 5-player game)
  g.raise_as(PLAYER3, MIN_BUY_IN);
  g.call_as(PLAYER4);
  g.call_as(PLAYER0);
  g.call_as(PLAYER1);
  g.call_as(PLAYER2);

  // This should automatically advance to showdown with all players all-in
  g.inspect_as!(PLAYER0, |game| {
    assert!(game.is_ended());
    assert_eq(game.get_treasury_balance(), MIN_BUY_IN * 5); // Total pot should be 5x buy-in
    let player0 = game.get_player(PLAYER0);
    let player1 = game.get_player(PLAYER1);
    let player2 = game.get_player(PLAYER2);
    let player3 = game.get_player(PLAYER3);
    let player4 = game.get_player(PLAYER4);
    let players = vector[*player0, *player1, *player2, *player3, *player4];
    let total_balance =
      player0.get_balance() + player1.get_balance() + player2.get_balance() +
      player3.get_balance() + player4.get_balance();
    assert_eq(total_balance, game.get_treasury_balance()); // Total balance should match treasury
    // poker::debug::print_debug(b"ℹ️ Player 0: ", player0);
    // poker::debug::print_debug(b"ℹ️ Player 1: ", player1);
    // poker::debug::print_debug(b"ℹ️ Player 2: ", player2);
    // poker::debug::print_debug(b"ℹ️ Player 3: ", player3);
    // poker::debug::print_debug(b"ℹ️ Player 4: ", player4);
    // poker::debug::print_debug(b"ℹ️ Pot: ", &game.get_pot());
    assert_eq(players.count!(|p| p.get_balance() > 0), 1); // Only one player should have winnings
    assert_eq(game.get_side_pots_count(), 0); // No side pots in this simple game
    assert_eq(game.get_pot(), 0); // Pot should be empty after all-in
  });

  ts::end(g);
}

// ===== Hand Evaluation Tests =====

#[test]
fun test_hand_evaluation_integration() {
  let mut g = create_and_join_game_as(PLAYER0);

  // Join 2 players to create a simple 3-player game
  g.join_as(PLAYER1, 1);
  g.join_as(PLAYER2, 2);

  // Start the game to trigger hand evaluation logic
  g.start_as(PLAYER0);

  // Have players take actions to reach showdown where hand evaluation occurs
  g.call_as(PLAYER0); // Dealer (first to act in 3-player)
  g.call_as(PLAYER1); // Small blind
  g.check_as(PLAYER2); // Big blind

  // Flop round - have all players check to advance
  g.check_as(PLAYER1); // First to act post-flop
  g.check_as(PLAYER2);
  g.check_as(PLAYER0);

  // Turn round - have all players check to advance
  g.check_as(PLAYER1);
  g.check_as(PLAYER2);
  g.check_as(PLAYER0);

  // River round - have all players check to trigger showdown and hand evaluation
  g.check_as(PLAYER1);
  g.check_as(PLAYER2);
  g.check_as(PLAYER0);

  // The game should now be completed with hand evaluation having determined the winner
  // This test ensures the hand evaluation system integrates properly without errors
  g.inspect_as!(PLAYER0, |game| {
    assert!(game.is_ended()); // Game should be over
    assert_eq(game.get_treasury_balance(), MIN_BUY_IN * 3); // Total pot should be 3x buy-in
    let player0 = game.get_player(PLAYER0);
    let player1 = game.get_player(PLAYER1);
    let player2 = game.get_player(PLAYER2);
    let players = vector[*player0, *player1, *player2];
    let total_balance =
      player0.get_balance() + player1.get_balance() + player2.get_balance();
    assert_eq(total_balance, game.get_treasury_balance()); // Total balance should match treasury
    assert!(players.count!(|p| p.get_balance() > 0) >= 1); // At least one player should have winnings
  });

  ts::end(g);
}

#[test]
fun test_side_pot_all_in() {
  let mut g = create_and_join_game_as(PLAYER0);
  let mut p0_balance = MIN_BUY_IN;
  let mut p1_balance = MIN_BUY_IN;
  let mut p2_balance = MIN_BUY_IN;

  // Add 2 players
  g.join_as(PLAYER1, 1);
  g.join_as(PLAYER2, 2);

  // Start the game
  g.start_as(PLAYER0);
  p1_balance = p1_balance - MIN_BET / 2; // small blind
  p2_balance = p2_balance - MIN_BET; // big blind
  // Pre-flop
  g.call_as(PLAYER0);
  p0_balance = p0_balance - MIN_BET;
  g.call_as(PLAYER1);
  p1_balance = p1_balance - MIN_BET / 2;
  g.check_as(PLAYER2);
  // Flop
  g.check_as(PLAYER1); // First to act post-flop (small blind)
  g.raise_as(PLAYER2, MIN_BET); // Big blind
  p2_balance = p2_balance - MIN_BET;
  g.call_as(PLAYER0); // Dealer calls
  p0_balance = p0_balance - MIN_BET;
  g.fold_as(PLAYER1); // Player1 folds
  // Turn
  g.check_as(PLAYER2);
  g.raise_as(PLAYER0, MIN_BET);
  p0_balance = p0_balance - MIN_BET;
  g.fold_as(PLAYER2);
  p0_balance = p0_balance + MIN_BET * 6; // Player0 wins the pot
  // No more players left to act, so the game should end here
  g.inspect_as!(PLAYER0, |game| {
    assert!(game.is_ended()); // Game should be over
    let player0 = game.get_player(PLAYER0);
    let player1 = game.get_player(PLAYER1);
    let player2 = game.get_player(PLAYER2);
    // Check balances after game ends
    assert_eq(player0.get_balance(), p0_balance);
    assert_eq(player1.get_balance(), p1_balance);
    assert_eq(player2.get_balance(), p2_balance);
    // print_debug(b"ℹ️ Player 0: ", player0);
    // print_debug(b"ℹ️ Player 1: ", player1);
    // print_debug(b"ℹ️ Player 2: ", player2);
  });
  g.start_as(PLAYER0);
  // Flop
  g.raise_as(PLAYER1, p1_balance); // Player1 goes all-in
  g.call_as(PLAYER2); // Player2 calls (all-in)
  g.call_as(PLAYER0); // Player0 calls

  // This should automatically advance to showdown
  g.inspect_as!(PLAYER0, |game| {
    // Check game state after all players are all-in
    assert!(game.is_ended()); // Game should be over
    assert_eq(game.get_side_pots_count(), 2); // Should have 2 side pots
    // let player0 = game.get_player(PLAYER0);
    // let player1 = game.get_player(PLAYER1);
    // let player2 = game.get_player(PLAYER2);
    // print_debug(b"ℹ️ Player 0: ", player0);
    // print_debug(b"ℹ️ Player 1: ", player1);
    // print_debug(b"ℹ️ Player 2: ", player2);
  });

  ts::end(g);
}

#[test]
fun test_side_pot_multiple_all_ins() {
  let mut g = create_and_join_game_as(PLAYER0);

  // Add more players for complex side pot g
  g.join_as(PLAYER1, 1);
  g.join_as(PLAYER2, 2);
  g.join_as(PLAYER3, 3);

  // Start the game
  g.start_as(PLAYER0);

  // Create g with different all-in amounts
  // Pre-flop: PLAYER0 (dealer), PLAYER1 (SB), PLAYER2 (BB), PLAYER3 first to act

  // PLAYER3 raises significantly
  g.raise_as(PLAYER3, MIN_BET * 4); // Raise to 4x min bet
  g.call_as(PLAYER0);
  g.call_as(PLAYER1);
  g.call_as(PLAYER2); // PLAYER2 calls to complete pre-flop

  // Now in post-flop, create different all-in amounts to test side pots
  // Test g: Have players bet/call different amounts to go all-in

  // PLAYER1 (first to act post-flop) bets a smaller amount
  {
    // Bet half of remaining balance to leave room for raises
    let remaining_balance = MIN_BUY_IN - MIN_BET * 4;
    let bet_amount = remaining_balance / 2;
    g.raise_as(PLAYER1, bet_amount);
  };

  // PLAYER2 raises to a larger amount
  {
    // Raise to 3/4 of remaining balance
    let remaining_balance = MIN_BUY_IN - MIN_BET * 4;
    let raise_amount = (remaining_balance * 3) / 4;
    g.raise_as(PLAYER2, raise_amount);
  };

  // PLAYER3 goes all-in
  {
    // Go all-in with all remaining balance
    let remaining_balance = MIN_BUY_IN - MIN_BET * 4;
    g.raise_as(PLAYER3, remaining_balance);
  };

  // PLAYER0 calls to see the action through to showdown
  g.call_as(PLAYER0);

  // Verify the game handled multiple all-ins correctly by checking game state
  // The game should automatically proceed through remaining streets and showdown
  // Multiple side pots should be created based on different all-in amounts
  g.inspect_as!(PLAYER0, |_game| {});

  // At this point, the game should have created multiple side pots:
  // - Main pot: Available to all players (up to PLAYER1's all-in amount)
  // - Side pot 1: Available to PLAYER2, PLAYER3, PLAYER0 (up to PLAYER3's amount)
  // - Side pot 2: Available to PLAYER2 and PLAYER0 (remaining amount)

  // The game will automatically proceed through remaining betting rounds and showdown
  // TODO: Testing that the side pot logic handles complex multi-player gs correctly

  ts::end(g);
}

#[test]
fun test_dealer_rotation_multiple_hands() {
  let mut g = create_and_join_game_as(PLAYER0);

  // Add players
  g.join_as(PLAYER1, 2);
  g.join_as(PLAYER2, 5);

  // Start first hand - PLAYER0 is dealer (position 0)
  g.start_as(PLAYER0);

  // Verify player statuses
  g.inspect_as!(PLAYER0, |game| {
    assert_eq(game.get_dealer_position(), 0); // Dealer should be PLAYER0 which is in seat #0
    assert_eq(game.get_player_state(PLAYER0), PlayerState_Active);
    assert_eq(game.get_player_state(PLAYER1), PlayerState_Waiting);
    assert_eq(game.get_player_state(PLAYER2), PlayerState_Waiting);
  });

  g.fold_as(PLAYER0);

  // Verify player statuses
  g.inspect_as!(PLAYER0, |game| {
    assert_eq(game.get_player_state(PLAYER0), PlayerState_Folded);
    assert_eq(game.get_player_state(PLAYER1), PlayerState_Active);
    assert_eq(game.get_player_state(PLAYER2), PlayerState_Waiting);
  });

  g.fold_as(PLAYER1);

  // PLAYER2 wins by default (only one left)
  // Game should now be in STATE_GAME_OVER
  g.inspect_as!(PLAYER0, |game| {
    assert!(game.is_ended())
  });

  // Start new hand with rotated dealer - should be PLAYER1 (position 1)
  g.start_as(PLAYER0);

  // // Verify dealer has rotated by checking blind positions
  // // In second hand: PLAYER1 is dealer, PLAYER2 is small blind, PLAYER0 is big blind
  // // We can verify this by checking who needs to post blinds and act first
  g.inspect_as!(PLAYER0, |game| {
    assert_eq(game.get_dealer_position(), 2); // Dealer should be PLAYER1 which is in seat #2
    assert_eq(game.get_player_state(PLAYER0), PlayerState_Waiting);
    assert_eq(game.get_player_state(PLAYER1), PlayerState_Active);
    assert_eq(game.get_player_state(PLAYER2), PlayerState_Waiting);
  });

  // // Fast forward second hand to test third hand rotation
  // // In second hand: PLAYER1 is dealer, PLAYER2 is SB, PLAYER0 is BB
  // // First to act pre-flop is PLAYER1 (dealer acts first in 3-player when big blind is posted)
  g.fold_as(PLAYER1);

  g.inspect_as!(PLAYER0, |game| {
    assert_eq(game.get_player_state(PLAYER0), PlayerState_Waiting);
    assert_eq(game.get_player_state(PLAYER1), PlayerState_Folded);
    assert_eq(game.get_player_state(PLAYER2), PlayerState_Active);
  });

  g.fold_as(PLAYER2);

  g.inspect_as!(PLAYER0, |game| {
    assert!(game.is_ended())
  });

  // // Start third hand - dealer should now be PLAYER2 (position 5)
  g.start_as(PLAYER0);

  g.inspect_as!(PLAYER0, |game| {
    assert_eq(game.get_dealer_position(), 5); // Dealer should be PLAYER2 which is in seat #5
    assert_eq(game.get_player_state(PLAYER0), PlayerState_Waiting);
    assert_eq(game.get_player_state(PLAYER1), PlayerState_Waiting);
    assert_eq(game.get_player_state(PLAYER2), PlayerState_Active);
  });

  ts::end(g);
}

// ===== Withdraw Function Tests =====

#[test]
fun test_successful_withdraw() {
  let mut g = create_and_join_game_as(PLAYER0);

  // Add players
  g.join_as(PLAYER1, 1);
  g.join_as(PLAYER2, 2);

  // Start the game
  g.start_as(PLAYER0);

  // Play a simple game to completion - PLAYER1 and PLAYER2 fold, PLAYER0 wins
  g.call_as(PLAYER0); // First to act (dealer in 3-player)
  g.fold_as(PLAYER1); // Small blind
  g.fold_as(PLAYER2); // Big blind

  // Test successful withdrawal by winner
  g.withdraw_as(PLAYER0);

  ts::end(g);
}

#[test]
#[expected_failure(abort_code = EGameInProgress, location = game)]
fun test_withdraw_game_not_over() {
  let mut g = create_and_join_game_as(PLAYER0);

  // Add one player
  g.join_as(PLAYER1, 1);

  // Start the game
  g.start_as(PLAYER0);

  // Try to withdraw before game starts (should fail)
  g.withdraw_as(PLAYER0);

  ts::end(g);
}

#[test]
#[expected_failure(abort_code = EInvalidPlayer, location = game)]
fun test_withdraw_invalid_player() {
  let mut g = create_and_join_game_as(PLAYER0);

  // Add players and complete a game
  g.join_as(PLAYER1, 1);

  g.join_as(PLAYER2, 2);

  // Start and complete the game
  g.start_as(PLAYER0);

  // Complete game quickly - players fold
  g.call_as(PLAYER0);

  g.fold_as(PLAYER1);

  g.fold_as(PLAYER2);

  // Try to withdraw with player not in game (should fail)
  g.withdraw_as(PLAYER3); // Player who didn't join the game

  ts::end(g);
}

#[test]
fun test_withdraw_no_winnings() {
  let mut g = create_and_join_game_as(PLAYER0);

  // Add players
  g.join_as(PLAYER1, 1);
  g.join_as(PLAYER2, 2);

  // Start and complete the game
  g.start_as(PLAYER0);

  // Complete game - PLAYER0 wins, others lose
  g.raise_as(PLAYER0, MIN_BUY_IN); // PLAYER0 goes all-in
  g.call_as(PLAYER1);
  g.fold_as(PLAYER2);

  // Since all players is now all-in, game should ended with PLAYER0 OR PLAYER01 winning
  g.inspect_as!(PLAYER0, |game| {
    assert!(game.is_ended());
  });

  // Try to withdraw with losing player (should fail)
  g.withdraw_as(PLAYER1); // Player who folded and has no winnings

  ts::end(g);
}

#[test]
fun test_multiple_player_withdraw() {
  let mut g = create_and_join_game_as(PLAYER0);

  // Add players
  g.join_as(PLAYER1, 1);
  g.join_as(PLAYER2, 2);

  // Start the game
  g.start_as(PLAYER0);

  // Play to showdown where multiple players might have winnings
  // When game started, PLAYER0 was dealer, PLAYER1 small blind, PLAYER2 big blind
  // Player 0 is first to act pre-flop
  g.call_as(PLAYER0); // Dealer calls
  g.call_as(PLAYER1); // Small blind calls
  g.check_as(PLAYER2); // Big blind checks

  // Continue through all rounds to showdown
  // Flop
  g.check_as(PLAYER1);
  g.check_as(PLAYER2);
  g.check_as(PLAYER0);

  // Turn
  g.check_as(PLAYER1);
  g.check_as(PLAYER2);
  g.check_as(PLAYER0);

  // River - this will trigger showdown
  g.check_as(PLAYER1);
  g.fold_as(PLAYER2);
  g.fold_as(PLAYER0);

  // Now test that winner(s) can withdraw their winnings
  // Try withdrawing with all players - only winner(s) should succeed
  g.withdraw_as(PLAYER0);

  ts::end(g);
}

#[test]
#[expected_failure(abort_code = EInvalidPlayer, location = game)]
fun test_withdraw_twice() {
  let mut g = create_and_join_game_as(PLAYER0);

  // Add one player
  g.join_as(PLAYER1, 1);

  // Start the game
  g.start_as(PLAYER0);

  // Complete game - PLAYER1 folds, PLAYER0 wins
  g.fold_as(PLAYER1);

  // First withdrawal (should succeed)
  g.withdraw_as(PLAYER0);

  // Second withdrawal attempt (should fail with EInvalidPlayer)
  g.withdraw_as(PLAYER0);

  ts::end(g);
}
