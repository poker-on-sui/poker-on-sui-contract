#[test_only]
module droplet_poker::game_tests;

use droplet_poker::game::{Self, PokerGame};
use sui::coin::{Self, Coin};
use sui::random::new_generator_for_testing;
use sui::sui::SUI;
use sui::test_scenario::{Self as ts, Scenario};

// Test addresses
const ADMIN: address = @0xABCD;
const PLAYER1: address = @0x1111;
const PLAYER2: address = @0x2222;
const PLAYER3: address = @0x3333;
const PLAYER4: address = @0x4444;
const SEED_LENGTH: u64 = 32;

// Game configuration constants
const BUY_IN: u64 = 1000000000; // 1 SUI
const MIN_BET: u64 = 10000000; // 0.01 SUI
const SMALL_BLIND: u64 = 10000000; // 0.01 SUI
const BIG_BLIND: u64 = 20000000; // 0.02 SUI

// Error codes from the poker module (only keeping used ones for warnings)
// Unused constants removed to eliminate compiler warnings

// Helper function to set up a test scenario with a created game
fun setup_game(): Scenario {
  let mut scenario = ts::begin(ADMIN);
  {
    // Create the poker game
    game::create_game(
      BUY_IN,
      MIN_BET,
      SMALL_BLIND,
      BIG_BLIND,
      ts::ctx(&mut scenario),
    );
  };
  scenario
}

// Helper function to create a new random number generator
entry fun generate_seed_for_test(): vector<u8> {
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

// Helper function to mint SUI for testing
fun mint_sui(amount: u64, ctx: &mut TxContext): Coin<SUI> {
  coin::mint_for_testing<SUI>(amount, ctx)
}

#[test]
fun test_create_game() {
  let mut scenario = ts::begin(ADMIN);
  {
    // Create a game
    game::create_game(
      BUY_IN,
      MIN_BET,
      SMALL_BLIND,
      BIG_BLIND,
      ts::ctx(&mut scenario),
    );
  };
  // Check that the game was created
  ts::next_tx(&mut scenario, ADMIN);
  {
    assert!(ts::has_most_recent_shared<PokerGame>(), 0);
    let game = ts::take_shared<PokerGame>(&scenario);
    ts::return_shared(game);
  };
  ts::end(scenario);
}

#[test]
fun test_join_game() {
  let mut scenario = setup_game();

  // Player 1 joins
  ts::next_tx(&mut scenario, PLAYER1);
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    let coin = mint_sui(BUY_IN, ts::ctx(&mut scenario));
    game::join_game(&mut game, coin, ts::ctx(&mut scenario));
    ts::return_shared(game);
  };

  // Player 2 joins
  ts::next_tx(&mut scenario, PLAYER2);
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    let coin = mint_sui(BUY_IN, ts::ctx(&mut scenario));
    game::join_game(&mut game, coin, ts::ctx(&mut scenario));
    ts::return_shared(game);
  };

  ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 2, location = game)]
// EInsufficientBuyIn from poker module
fun test_join_game_insufficient_buy_in() {
  let mut scenario = setup_game();

  // Player tries to join with insufficient funds
  ts::next_tx(&mut scenario, PLAYER1);
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    let coin = mint_sui(BUY_IN - 1, ts::ctx(&mut scenario)); // Less than required
    game::join_game(&mut game, coin, ts::ctx(&mut scenario));
    ts::return_shared(game);
  };

  ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 9, location = game)]
// EAlreadyJoined from poker module
fun test_join_game_already_joined() {
  let mut scenario = setup_game();

  // Player 1 joins
  ts::next_tx(&mut scenario, PLAYER1);
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    let coin = mint_sui(BUY_IN, ts::ctx(&mut scenario));
    game::join_game(&mut game, coin, ts::ctx(&mut scenario));
    ts::return_shared(game);
  };

  // Player 1 tries to join again
  ts::next_tx(&mut scenario, PLAYER1);
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    let coin = mint_sui(BUY_IN, ts::ctx(&mut scenario));
    game::join_game(&mut game, coin, ts::ctx(&mut scenario)); // Should fail
    ts::return_shared(game);
  };

  ts::end(scenario);
}

#[test]
fun test_start_game() {
  let mut scenario = setup_game();

  // Add 2 players
  ts::next_tx(&mut scenario, PLAYER1);
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    let coin = mint_sui(BUY_IN, ts::ctx(&mut scenario));
    game::join_game(&mut game, coin, ts::ctx(&mut scenario));
    ts::return_shared(game);
  };

  ts::next_tx(&mut scenario, PLAYER2);
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    let coin = mint_sui(BUY_IN, ts::ctx(&mut scenario));
    game::join_game(&mut game, coin, ts::ctx(&mut scenario));
    ts::return_shared(game);
  };

  // Admin starts the game
  ts::next_tx(&mut scenario, ADMIN);
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    let seed = generate_seed_for_test();
    game::start_game_with_seed_for_testing(
      &mut game,
      seed,
      ts::ctx(&mut scenario),
    );
    ts::return_shared(game);
  };

  ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 4, location = game)]
// EInvalidPlayer from poker module
fun test_start_game_not_owner() {
  let mut scenario = setup_game();

  // Add 2 players
  ts::next_tx(&mut scenario, PLAYER1);
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    let coin = mint_sui(BUY_IN, ts::ctx(&mut scenario));
    game::join_game(&mut game, coin, ts::ctx(&mut scenario));
    ts::return_shared(game);
  };

  ts::next_tx(&mut scenario, PLAYER2);
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    let coin = mint_sui(BUY_IN, ts::ctx(&mut scenario));
    game::join_game(&mut game, coin, ts::ctx(&mut scenario));
    ts::return_shared(game);
  };

  // Player1 tries to start the game (not the owner)
  ts::next_tx(&mut scenario, PLAYER1);
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    let seed = generate_seed_for_test();
    game::start_game_with_seed_for_testing(
      &mut game,
      seed,
      ts::ctx(&mut scenario),
    ); // Should fail
    ts::return_shared(game);
  };

  ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = 10, location = game)]
fun test_start_game_invalid_seed() {
  let mut scenario = setup_game();

  // Add 2 players
  ts::next_tx(&mut scenario, PLAYER1);
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    let coin = mint_sui(BUY_IN, ts::ctx(&mut scenario));
    game::join_game(&mut game, coin, ts::ctx(&mut scenario));
    ts::return_shared(game);
  };

  ts::next_tx(&mut scenario, PLAYER2);
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    let coin = mint_sui(BUY_IN, ts::ctx(&mut scenario));
    game::join_game(&mut game, coin, ts::ctx(&mut scenario));
    ts::return_shared(game);
  };

  // Admin tries to start game with empty seed
  ts::next_tx(&mut scenario, ADMIN);
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    let empty_seed = std::vector::empty<u8>(); // Empty seed
    game::start_game_with_seed_for_testing(
      &mut game,
      empty_seed,
      ts::ctx(&mut scenario),
    ); // Should fail
    ts::return_shared(game);
  };

  ts::end(scenario);
}

#[test]
fun test_player_actions() {
  let mut scenario = setup_game();

  // Add 4 players
  ts::next_tx(&mut scenario, PLAYER1);
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    let coin = mint_sui(BUY_IN, ts::ctx(&mut scenario));
    game::join_game(&mut game, coin, ts::ctx(&mut scenario));
    ts::return_shared(game);
  };

  ts::next_tx(&mut scenario, PLAYER2);
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    let coin = mint_sui(BUY_IN, ts::ctx(&mut scenario));
    game::join_game(&mut game, coin, ts::ctx(&mut scenario));
    ts::return_shared(game);
  };

  ts::next_tx(&mut scenario, PLAYER3);
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    let coin = mint_sui(BUY_IN, ts::ctx(&mut scenario));
    game::join_game(&mut game, coin, ts::ctx(&mut scenario));
    ts::return_shared(game);
  };

  ts::next_tx(&mut scenario, PLAYER4);
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    let coin = mint_sui(BUY_IN, ts::ctx(&mut scenario));
    game::join_game(&mut game, coin, ts::ctx(&mut scenario));
    ts::return_shared(game);
  };

  // Start the game
  ts::next_tx(&mut scenario, ADMIN);
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    let seed = generate_seed_for_test();
    game::start_game_with_seed_for_testing(
      &mut game,
      seed,
      ts::ctx(&mut scenario),
    );
    ts::return_shared(game);
  };

  // Test player actions - first player after big blind calls
  ts::next_tx(&mut scenario, PLAYER4); // Player after big blind
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    // Call the big blind
    game::player_action(&mut game, 2, 0, ts::ctx(&mut scenario)); // ACTION_CALL = 2
    ts::return_shared(game);
  };

  // Next player raises
  ts::next_tx(&mut scenario, PLAYER1);
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    // Raise to 3x big blind
    game::player_action(&mut game, 4, BIG_BLIND * 3, ts::ctx(&mut scenario)); // ACTION_RAISE = 4
    ts::return_shared(game);
  };

  // Small blind player folds
  ts::next_tx(&mut scenario, PLAYER2);
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    // Fold
    game::player_action(&mut game, 0, 0, ts::ctx(&mut scenario)); // ACTION_FOLD = 0
    ts::return_shared(game);
  };

  // Big blind player calls
  ts::next_tx(&mut scenario, PLAYER3);
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    // Call the raise
    game::player_action(&mut game, 2, 0, ts::ctx(&mut scenario)); // ACTION_CALL = 2
    ts::return_shared(game);
  };

  ts::end(scenario);
}

#[test]
fun test_full_game_flow() {
  let mut scenario = setup_game();

  // Add 2 players
  ts::next_tx(&mut scenario, PLAYER1);
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    let coin = mint_sui(BUY_IN, ts::ctx(&mut scenario));
    game::join_game(&mut game, coin, ts::ctx(&mut scenario));
    ts::return_shared(game);
  };

  ts::next_tx(&mut scenario, PLAYER2);
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    let coin = mint_sui(BUY_IN, ts::ctx(&mut scenario));
    game::join_game(&mut game, coin, ts::ctx(&mut scenario));
    ts::return_shared(game);
  };

  // Start the game
  ts::next_tx(&mut scenario, ADMIN);
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    let seed = generate_seed_for_test();
    game::start_game_with_seed_for_testing(
      &mut game,
      seed,
      ts::ctx(&mut scenario),
    );
    ts::return_shared(game);
  };

  // Pre-flop actions
  ts::next_tx(&mut scenario, PLAYER2); // Big blind acts first in 2-player
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    // Call
    game::player_action(&mut game, 2, 0, ts::ctx(&mut scenario));
    ts::return_shared(game);
  };

  ts::next_tx(&mut scenario, PLAYER1); // Dealer/small blind acts second
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    // Call
    game::player_action(&mut game, 2, 0, ts::ctx(&mut scenario));
    ts::return_shared(game);
  };

  // Flop actions
  ts::next_tx(&mut scenario, PLAYER2); // First player after flop
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    // Check
    game::player_action(&mut game, 1, 0, ts::ctx(&mut scenario));
    ts::return_shared(game);
  };

  ts::next_tx(&mut scenario, PLAYER1);
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    // Check
    game::player_action(&mut game, 1, 0, ts::ctx(&mut scenario));
    ts::return_shared(game);
  };

  // Turn actions
  ts::next_tx(&mut scenario, PLAYER2);
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    // Bet
    game::player_action(&mut game, 3, MIN_BET, ts::ctx(&mut scenario));
    ts::return_shared(game);
  };

  ts::next_tx(&mut scenario, PLAYER1);
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    // Call
    game::player_action(&mut game, 2, 0, ts::ctx(&mut scenario));
    ts::return_shared(game);
  };

  // River actions
  ts::next_tx(&mut scenario, PLAYER2);
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    // Check
    game::player_action(&mut game, 1, 0, ts::ctx(&mut scenario));
    ts::return_shared(game);
  };

  ts::next_tx(&mut scenario, PLAYER1);
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    // Check - this should trigger showdown
    game::player_action(&mut game, 1, 0, ts::ctx(&mut scenario));
    ts::return_shared(game);
  };

  // Game should be over now

  ts::end(scenario);
}

#[test]
fun test_all_in_scenario() {
  let mut scenario = setup_game();

  // Add 2 players
  ts::next_tx(&mut scenario, PLAYER1);
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    let coin = mint_sui(BUY_IN, ts::ctx(&mut scenario));
    game::join_game(&mut game, coin, ts::ctx(&mut scenario));
    ts::return_shared(game);
  };

  ts::next_tx(&mut scenario, PLAYER2);
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    let coin = mint_sui(BUY_IN, ts::ctx(&mut scenario));
    game::join_game(&mut game, coin, ts::ctx(&mut scenario));
    ts::return_shared(game);
  };

  // Start the game
  ts::next_tx(&mut scenario, ADMIN);
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    let seed = generate_seed_for_test();
    game::start_game_with_seed_for_testing(
      &mut game,
      seed,
      ts::ctx(&mut scenario),
    );
    ts::return_shared(game);
  };

  // Player2 goes all-in pre-flop (big blind acts first in 2-player)
  ts::next_tx(&mut scenario, PLAYER2);
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    // Raise to all-in
    game::player_action(&mut game, 4, BUY_IN, ts::ctx(&mut scenario));
    ts::return_shared(game);
  };

  // Player1 calls
  ts::next_tx(&mut scenario, PLAYER1);
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    // Call the all-in
    game::player_action(&mut game, 2, 0, ts::ctx(&mut scenario));
    ts::return_shared(game);
  };

  // This should automatically advance to showdown

  ts::end(scenario);
}

#[test]
fun test_four_player_game_flow() {
  let mut scenario = setup_game();

  // Add 4 players
  ts::next_tx(&mut scenario, PLAYER1);
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    let coin = mint_sui(BUY_IN, ts::ctx(&mut scenario));
    game::join_game(&mut game, coin, ts::ctx(&mut scenario));
    ts::return_shared(game);
  };

  ts::next_tx(&mut scenario, PLAYER2);
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    let coin = mint_sui(BUY_IN, ts::ctx(&mut scenario));
    game::join_game(&mut game, coin, ts::ctx(&mut scenario));
    ts::return_shared(game);
  };

  ts::next_tx(&mut scenario, PLAYER3);
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    let coin = mint_sui(BUY_IN, ts::ctx(&mut scenario));
    game::join_game(&mut game, coin, ts::ctx(&mut scenario));
    ts::return_shared(game);
  };

  ts::next_tx(&mut scenario, PLAYER4);
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    let coin = mint_sui(BUY_IN, ts::ctx(&mut scenario));
    game::join_game(&mut game, coin, ts::ctx(&mut scenario));
    ts::return_shared(game);
  };

  // Start the game
  ts::next_tx(&mut scenario, ADMIN);
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    let seed = generate_seed_for_test();
    game::start_game_with_seed_for_testing(
      &mut game,
      seed,
      ts::ctx(&mut scenario),
    );
    ts::return_shared(game);
  };

  // Pre-flop actions (4 players: P1=dealer, P2=small blind, P3=big blind, P4=first to act)
  ts::next_tx(&mut scenario, PLAYER4); // First player after big blind
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    // Call
    game::player_action(&mut game, 2, 0, ts::ctx(&mut scenario));
    ts::return_shared(game);
  };

  ts::next_tx(&mut scenario, PLAYER1); // Dealer
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    // Call
    game::player_action(&mut game, 2, 0, ts::ctx(&mut scenario));
    ts::return_shared(game);
  };

  ts::next_tx(&mut scenario, PLAYER2); // Small blind
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    // Call (complete the small blind)
    game::player_action(&mut game, 2, 0, ts::ctx(&mut scenario));
    ts::return_shared(game);
  };

  ts::next_tx(&mut scenario, PLAYER3); // Big blind
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    // Check
    game::player_action(&mut game, 1, 0, ts::ctx(&mut scenario));
    ts::return_shared(game);
  };

  // Flop actions (all players check)
  ts::next_tx(&mut scenario, PLAYER2); // First to act after flop
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    // Check
    game::player_action(&mut game, 1, 0, ts::ctx(&mut scenario));
    ts::return_shared(game);
  };

  ts::next_tx(&mut scenario, PLAYER3);
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    // Check
    game::player_action(&mut game, 1, 0, ts::ctx(&mut scenario));
    ts::return_shared(game);
  };

  ts::next_tx(&mut scenario, PLAYER4);
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    // Check
    game::player_action(&mut game, 1, 0, ts::ctx(&mut scenario));
    ts::return_shared(game);
  };

  ts::next_tx(&mut scenario, PLAYER1);
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    // Check
    game::player_action(&mut game, 1, 0, ts::ctx(&mut scenario));
    ts::return_shared(game);
  };

  // Turn actions
  ts::next_tx(&mut scenario, PLAYER2);
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    // Bet
    game::player_action(&mut game, 3, MIN_BET, ts::ctx(&mut scenario));
    ts::return_shared(game);
  };

  ts::next_tx(&mut scenario, PLAYER3);
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    // Fold
    game::player_action(&mut game, 0, 0, ts::ctx(&mut scenario));
    ts::return_shared(game);
  };

  ts::next_tx(&mut scenario, PLAYER4);
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    // Call
    game::player_action(&mut game, 2, 0, ts::ctx(&mut scenario));
    ts::return_shared(game);
  };

  ts::next_tx(&mut scenario, PLAYER1);
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    // Raise
    game::player_action(&mut game, 4, MIN_BET * 2, ts::ctx(&mut scenario));
    ts::return_shared(game);
  };

  ts::next_tx(&mut scenario, PLAYER2);
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    // Fold
    game::player_action(&mut game, 0, 0, ts::ctx(&mut scenario));
    ts::return_shared(game);
  };

  ts::next_tx(&mut scenario, PLAYER4);
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    // Call
    game::player_action(&mut game, 2, 0, ts::ctx(&mut scenario));
    ts::return_shared(game);
  };

  // River actions
  ts::next_tx(&mut scenario, PLAYER4);
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    // Check
    game::player_action(&mut game, 1, 0, ts::ctx(&mut scenario));
    ts::return_shared(game);
  };

  ts::next_tx(&mut scenario, PLAYER1);
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    // Check - this should trigger showdown
    game::player_action(&mut game, 1, 0, ts::ctx(&mut scenario));
    ts::return_shared(game);
  };

  // Game should be over now with PLAYER1 and PLAYER4 remaining

  ts::end(scenario);
}

#[test]
fun test_four_player_join_game() {
  let mut scenario = setup_game();

  // Player 1 joins
  ts::next_tx(&mut scenario, PLAYER1);
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    let coin = mint_sui(BUY_IN, ts::ctx(&mut scenario));
    game::join_game(&mut game, coin, ts::ctx(&mut scenario));
    ts::return_shared(game);
  };

  // Player 2 joins
  ts::next_tx(&mut scenario, PLAYER2);
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    let coin = mint_sui(BUY_IN, ts::ctx(&mut scenario));
    game::join_game(&mut game, coin, ts::ctx(&mut scenario));
    ts::return_shared(game);
  };

  // Player 3 joins
  ts::next_tx(&mut scenario, PLAYER3);
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    let coin = mint_sui(BUY_IN, ts::ctx(&mut scenario));
    game::join_game(&mut game, coin, ts::ctx(&mut scenario));
    ts::return_shared(game);
  };

  // Player 4 joins
  ts::next_tx(&mut scenario, PLAYER4);
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    let coin = mint_sui(BUY_IN, ts::ctx(&mut scenario));
    game::join_game(&mut game, coin, ts::ctx(&mut scenario));
    ts::return_shared(game);
  };

  ts::end(scenario);
}

#[test]
fun test_four_player_all_in_scenario() {
  let mut scenario = setup_game();

  // Add 4 players
  ts::next_tx(&mut scenario, PLAYER1);
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    let coin = mint_sui(BUY_IN, ts::ctx(&mut scenario));
    game::join_game(&mut game, coin, ts::ctx(&mut scenario));
    ts::return_shared(game);
  };

  ts::next_tx(&mut scenario, PLAYER2);
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    let coin = mint_sui(BUY_IN, ts::ctx(&mut scenario));
    game::join_game(&mut game, coin, ts::ctx(&mut scenario));
    ts::return_shared(game);
  };

  ts::next_tx(&mut scenario, PLAYER3);
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    let coin = mint_sui(BUY_IN, ts::ctx(&mut scenario));
    game::join_game(&mut game, coin, ts::ctx(&mut scenario));
    ts::return_shared(game);
  };

  ts::next_tx(&mut scenario, PLAYER4);
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    let coin = mint_sui(BUY_IN, ts::ctx(&mut scenario));
    game::join_game(&mut game, coin, ts::ctx(&mut scenario));
    ts::return_shared(game);
  };

  // Start the game
  ts::next_tx(&mut scenario, ADMIN);
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    let seed = generate_seed_for_test();
    game::start_game_with_seed_for_testing(
      &mut game,
      seed,
      ts::ctx(&mut scenario),
    );
    ts::return_shared(game);
  };

  // Player4 goes all-in pre-flop
  ts::next_tx(&mut scenario, PLAYER4);
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    // Raise to all-in
    game::player_action(&mut game, 4, BUY_IN, ts::ctx(&mut scenario));
    ts::return_shared(game);
  };

  // Player1 calls
  ts::next_tx(&mut scenario, PLAYER1);
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    // Call the all-in
    game::player_action(&mut game, 2, 0, ts::ctx(&mut scenario));
    ts::return_shared(game);
  };

  // Player2 folds
  ts::next_tx(&mut scenario, PLAYER2);
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    // Fold
    game::player_action(&mut game, 0, 0, ts::ctx(&mut scenario));
    ts::return_shared(game);
  };

  // Player3 calls
  ts::next_tx(&mut scenario, PLAYER3);
  {
    let mut game = ts::take_shared<PokerGame>(&scenario);
    // Call the all-in
    game::player_action(&mut game, 2, 0, ts::ctx(&mut scenario));
    ts::return_shared(game);
  };

  // This should automatically advance to showdown with 3 players all-in

  ts::end(scenario);
}
