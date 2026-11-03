# Same acceptance conditions as the frozen, board-verified PL30 system.
proc y26_signoff {reports} {
 file mkdir $reports
 report_timing_summary -file [file join $reports timing_summary.rpt]
 report_utilization -hierarchical -file [file join $reports utilization.rpt]
 report_drc -file [file join $reports drc.rpt]
 report_route_status -file [file join $reports route_status.rpt]
 check_timing -verbose -file [file join $reports check_timing.rpt]
 set f [open [file join $reports check_timing.rpt] r];set coverage [read $f];close $f
 foreach n {no_clock constant_clock pulse_width_clock unconstrained_internal_endpoints no_input_delay no_output_delay multiple_clock generated_clocks loops partial_input_delay partial_output_delay latch_loops} {
  if {![regexp [format {checking %s \(([0-9]+)\)} $n] $coverage -> value] || $value!=0} {error "Timing coverage failed: $n"}
 }
 set f [open [file join $reports route_status.rpt] r];set route [read $f];close $f
 if {![regexp {nets with routing errors[^:]*:[ ]*([0-9]+)} $route -> errors] || $errors!=0} {error "Unrouted or conflicting nets remain"}
 set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
 set whs [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]
 set drc [llength [get_drc_violations -quiet -filter {SEVERITY == Error}]]
 set cores [llength [get_cells -hier -filter {ORIG_REF_NAME == y26_conv_tile}]]
 set dsps [llength [get_cells -hier -filter {REF_NAME == DSP48E1}]]
 set ram36 [llength [get_cells -hier -filter {REF_NAME == RAMB36E1}]]
 set ram18 [llength [get_cells -hier -filter {REF_NAME == RAMB18E1}]]
 set partial36 [llength [get_cells -hier -filter {REF_NAME == RAMB36E1 && NAME =~ *partial*}]]
 set partial18 [llength [get_cells -hier -filter {REF_NAME == RAMB18E1 && NAME =~ *partial*}]]
 set bram [expr {$ram36+$ram18/2.0}]
 set passed [expr {$wns>=0 && $whs>=0 && $drc==0 && $cores==1 && $dsps<=110 && $bram<=140 && $partial36==16 && $partial18==0}]
 set f [open [file join $reports result.json] w]
 puts $f "{\"timing_pass\":[expr {$passed?{true}:{false}}],\"wns_ns\":$wns,\"whs_ns\":$whs,\"drc_errors\":$drc,\"compute_units\":$cores,\"dsp\":$dsps,\"bram36_equivalent\":$bram,\"partial_ramb36\":$partial36,\"partial_ramb18\":$partial18,\"timing_categories_checked\":12,\"board_programmed\":false}"
 close $f
 if {!$passed} {error "Signoff failed; no bitstream export and no board configuration"}
}
