----------------------------------------------------------------------------------
-- Company: 
-- Engineer: 
-- 
-- Create Date: 03.09.2025 07:26:38
-- Design Name: 
-- Module Name: bldc_pos_compact - Behavioral
-- Project Name: 
-- Target Devices: 
-- Tool Versions: 
-- Description: 
-- 
-- Dependencies: 
-- 
-- Revision:
-- Revision 0.01 - File Created
-- Additional Comments:
-- 
----------------------------------------------------------------------------------


library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

-- Uncomment the following library declaration if using
-- arithmetic functions with Signed or Unsigned values
--use IEEE.NUMERIC_STD.ALL;

-- Uncomment the following library declaration if instantiating
-- any Xilinx leaf cells in this code.
--library UNISIM;
--use UNISIM.VComponents.all;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity bldc_pos_compact is
  generic(
    SECT_W : integer := 20;  -- sector timer width
    ROT_W  : integer := 28;  -- rotation timer width
    POS_W  : integer := 32   -- position counter width (signed)
  );
  port(
    clk  : in  std_logic;
    rstn : in  std_logic;                     -- active-low synchronous reset
    hall : in  std_logic_vector(2 downto 0);  -- raw 3 hall signals

    sector           : out unsigned(2 downto 0);  -- 0..5
    sector_valid     : out std_logic;
    dir              : out std_logic;             -- '1' CW, '0' CCW
    pos_count        : out signed(POS_W-1 downto 0);

    sector_timer     : out unsigned(SECT_W-1 downto 0);  -- running timer
    last_sector_time : out unsigned(SECT_W-1 downto 0);  -- latched at each valid edge

    rot_timer        : out unsigned(ROT_W-1 downto 0);   -- running timer in current window
    rot_time_out     : out unsigned(ROT_W-1 downto 0);   -- latched on full 6 sectors
    rot_valid        : out std_logic;                    -- 1-cycle pulse

    partial_rot_time : out unsigned(ROT_W-1 downto 0);   -- latched on reversal
    partial_valid    : out std_logic                     -- 1-cycle pulse
  );
end entity;

architecture rtl of bldc_pos_compact is
  -- 2-FF hall synchronizers
  signal h1, h2 : std_logic_vector(2 downto 0) := (others=>'0');

  -- decode
  signal sec_curr, sec_prev : unsigned(2 downto 0) := (others=>'0');
  signal valid_s : std_logic := '0';

  -- direction/state
  signal dir_curr   : std_logic := '0';
  signal dir_prev   : std_logic := '0';
  signal have_dir   : std_logic := '0';

  -- counters/timers
  signal s_cnt    : unsigned(SECT_W-1 downto 0) := (others=>'0');
  signal s_last   : unsigned(SECT_W-1 downto 0) := (others=>'0');

  signal r_cnt    : unsigned(ROT_W-1 downto 0) := (others=>'0');
  signal r_out    : unsigned(ROT_W-1 downto 0) := (others=>'0');
  signal r_vp     : std_logic := '0';

  signal p_cnt    : signed(POS_W-1 downto 0) := (others=>'0');
  signal p_time   : unsigned(ROT_W-1 downto 0) := (others=>'0');
  signal p_vp     : std_logic := '0';

  signal sectors_acc : unsigned(2 downto 0) := (others=>'0'); -- 0..6
  signal rot_active  : std_logic := '0';

  -- helpers
  function next_cw(p,c:unsigned(2 downto 0)) return boolean is
  begin
    return ((to_integer(p)+1) mod 6) = to_integer(c);
  end;
  function next_ccw(p,c:unsigned(2 downto 0)) return boolean is
  begin
    return ((to_integer(p)+5) mod 6) = to_integer(c); -- -1 mod 6
  end;

begin
  -- synchronize halls
  process(clk)
  begin
    if rising_edge(clk) then
      if rstn='0' then
        h1 <= (others=>'0'); h2 <= (others=>'0');
      else
        h1 <= hall; h2 <= h1;
      end if;
    end if;
  end process;

  -- hall -> sector decode (adjust mapping for your wiring if needed)
  process(h2)
  begin
    valid_s <= '1';
    case h2 is
      when "001" => sec_curr <= to_unsigned(0,3);
      when "011" => sec_curr <= to_unsigned(1,3);
      when "010" => sec_curr <= to_unsigned(2,3);
      when "110" => sec_curr <= to_unsigned(3,3);
      when "100" => sec_curr <= to_unsigned(4,3);
      when "101" => sec_curr <= to_unsigned(5,3);
      when others => sec_curr <= (others=>'0'); valid_s <= '0';
    end case;
  end process;

  -- main state/timer logic
  process(clk)
    -- in-cycle variables (avoid signal read-after-write issues)
    variable v_change      : boolean;
    variable v_valid_step  : boolean;
    variable v_is_cw       : boolean;
    variable v_is_ccw      : boolean;
    variable v_new_dir     : std_logic;
    variable v_reverse     : boolean;
  begin
    if rising_edge(clk) then
      if rstn='0' then
        sec_prev    <= (others=>'0');
        dir_curr    <= '0'; dir_prev <= '0'; have_dir <= '0';
        s_cnt       <= (others=>'0'); s_last <= (others=>'0');
        r_cnt       <= (others=>'0'); r_out  <= (others=>'0'); r_vp <= '0';
        p_cnt       <= (others=>'0'); p_time <= (others=>'0'); p_vp <= '0';
        sectors_acc <= (others=>'0'); rot_active <= '0';
      else
        -- defaults each cycle
        r_vp <= '0';
        p_vp <= '0';

        -- free-running timers
        s_cnt <= s_cnt + 1;
        if rot_active='1' then
          r_cnt <= r_cnt + 1;
        end if;

        -- evaluate transition using variables
        v_change     := (valid_s='1') and (sec_curr /= sec_prev);
        v_is_cw      := false;
        v_is_ccw     := false;
        v_valid_step := false;
        v_new_dir    := dir_curr;
        v_reverse    := false;

        if v_change then
          v_is_cw      := next_cw(sec_prev, sec_curr);
          v_is_ccw     := next_ccw(sec_prev, sec_curr);
          v_valid_step := v_is_cw or v_is_ccw;

          if v_valid_step then
            -- compute new direction (variable)
            if v_is_cw then v_new_dir := '1'; else v_new_dir := '0'; end if;

            -- sector timer latch/reset
            s_last <= s_cnt;
            s_cnt  <= (others=>'0');

            -- position update
            if v_new_dir='1' then p_cnt <= p_cnt + 1; else p_cnt <= p_cnt - 1; end if;

            -- decide reversal
            if have_dir='1' and (v_new_dir /= dir_prev) then
              v_reverse := true;
            end if;

            -- rotation window
            if rot_active='0' then
              rot_active  <= '1';
              r_cnt       <= (others=>'0');      -- start from 0 at this edge
              sectors_acc <= to_unsigned(1,3);   -- count this first edge
              dir_prev    <= v_new_dir;
              have_dir    <= '1';
            else
              if v_reverse then
                -- latch partial and restart accumulation
                p_time     <= r_cnt;  p_vp <= '1';
                r_cnt      <= (others=>'0');
                sectors_acc<= to_unsigned(1,3);
                dir_prev   <= v_new_dir;
              else
                -- same direction continues
                if sectors_acc < to_unsigned(6,3) then
                  sectors_acc <= sectors_acc + 1;
                end if;
                if sectors_acc = to_unsigned(5,3) then -- full 6 sectors complete
                  r_out  <= r_cnt;  r_vp <= '1';
                  r_cnt  <= (others=>'0');
                  sectors_acc <= to_unsigned(1,3);  -- start new window
                end if;
                dir_prev <= v_new_dir;
              end if;
            end if;

            -- commit current direction
            dir_curr <= v_new_dir;

            -- ONLY update sec_prev on valid step (ignore skipped/invalid jumps)
            sec_prev <= sec_curr;
          else
            -- invalid multi-sector jump: ignore (do not update sec_prev)
            null;
          end if;
        end if; -- v_change
      end if; -- rstn
    end if; -- clock
  end process;

  -- outputs
  sector           <= sec_curr;
  sector_valid     <= valid_s;
  dir              <= dir_curr;

  sector_timer     <= s_cnt;
  last_sector_time <= s_last;

  rot_timer        <= r_cnt;
  rot_time_out     <= r_out;
  rot_valid        <= r_vp;

  partial_rot_time <= p_time;
  partial_valid    <= p_vp;

end architecture;

