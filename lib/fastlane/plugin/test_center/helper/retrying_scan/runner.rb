
module TestCenter
  module Helper
    module RetryingScan
      require 'fastlane_core/ui/ui.rb'
      require 'plist'
      require 'json'
      require 'pry-byebug'

      class Runner
        Parallelization = TestCenter::Helper::RetryingScan::Parallelization

        attr_reader :retry_total_count

        def initialize(multi_scan_options)
          @try_count = multi_scan_options[:try_count]
          @retry_total_count = 0
          @testrun_completed_block = multi_scan_options[:testrun_completed_block]
          @given_custom_report_file_name = multi_scan_options[:custom_report_file_name]
          @given_output_types = multi_scan_options[:output_types]
          @given_output_files = multi_scan_options[:output_files]
          @parallelize = multi_scan_options[:parallelize]
          @test_collector = TestCollector.new(multi_scan_options)
          @scan_options = multi_scan_options.reject do |option, _|
            %i[
              output_directory
              only_testing
              skip_testing
              clean
              try_count
              batch_count
              custom_report_file_name
              fail_build
              testrun_completed_block
              output_types
              output_files
              parallelize
            ].include?(option)
          end
          @scan_options[:clean] = false
          @scan_options[:disable_concurrent_testing] = true
          @scan_options[:xctestrun] = @test_collector.xctestrun_path
          @batch_count = @test_collector.test_batches.size
          if @parallelize
            @scan_options.delete(:derived_data_path)
            @parallelizer = Parallelization.new(@batch_count)
          end
        end

        def scan
          all_tests_passed = true
          @testables_count = @test_collector.testables.size
          @test_collector.test_batches.each_with_index do |test_batch, current_batch_index|
            puts "current_batch_index: #{current_batch_index}"
          end
          all_tests_passed = each_batch do |test_batch, current_batch_index|
            output_directory = testrun_output_directory(test_batch, current_batch_index)
            reset_for_new_testable(output_directory)
            FastlaneCore::UI.header("Starting test run on batch '#{current_batch_index}'")
            @interstitial.batch = current_batch_index
            @interstitial.output_directory = output_directory
            @interstitial.before_all
            testrun_passed = correcting_scan(
              {
                only_testing: test_batch,
                output_directory: output_directory
              },
              current_batch_index,
              @reportnamer
            )
            all_tests_passed = testrun_passed && all_tests_passed
            TestCenter::Helper::RetryingScan::ReportCollator.new(
              output_directory: output_directory,
              reportnamer: @reportnamer,
              scheme: @scan_options[:scheme],
              result_bundle: @scan_options[:result_bundle]
            ).collate
            testrun_passed && all_tests_passed
          end
          all_tests_passed
        end

        def each_batch
          tests_passed = true
          if @parallelize
            app_infoplist = XCTestrunInfo.new(@test_collector.xctestrun_path)
            batch_deploymentversions = @test_collector.test_batches.map do |test_batch|
              testable = test_batch.first.split('/').first.gsub('\\', '')
              app_infoplist.app_plist_for_testable(testable)['MinimumOSVersion']
            end
            @parallelizer.setup_simulators(@scan_options[:devices] || Array(@scan_options[:device]), batch_deploymentversions)
            @parallelizer.setup_pipes_for_fork
            @test_collector.test_batches.each_with_index do |test_batch, current_batch_index|
              fork do
                @parallelizer.connect_subprocess_endpoint(current_batch_index)
                begin
                  @parallelizer.setup_scan_options_for_testrun(@scan_options, current_batch_index)
                  tests_passed = yield(test_batch, current_batch_index)
                ensure
                  @parallelizer.send_subprocess_result(current_batch_index, tests_passed)
                end
                sleep(5) # give time for the xcodebuild command and children 
                # processes to disconnect from the Simulator subsystems 
                exit(true) # last command to ensure subprocess ends quickly.
              end
            end
            @parallelizer.wait_for_subprocesses
            tests_passed = @parallelizer.handle_subprocesses_results && tests_passed
            @parallelizer.cleanup_simulators
          else
            @test_collector.test_batches.each_with_index do |test_batch, current_batch_index|
              tests_passed = yield(test_batch, current_batch_index)
            end
          end
          tests_passed
        end

        def testrun_output_directory(test_batch, batch_index)
          @output_directory = @scan_options[:output_directory] || 'test_results'
          if @test_collector.testables.one?
            @output_directory
          else
            testable_name = test_batch.first.split('/').first
            File.join(@output_directory, "results-#{testable_name}-batch-#{batch_index}")
          end
        end

        def reset_reportnamer
          @reportnamer = ReportNameHelper.new(
            @given_output_types,
            @given_output_files,
            @given_custom_report_file_name
          )
        end

        def reset_interstitial(output_directory)
          @interstitial = TestCenter::Helper::RetryingScan::Interstitial.new(
            @scan_options.merge(
              {
                output_directory: output_directory,
                reportnamer: @reportnamer,
                parallelize: @parallelize
              }
            )
          )
        end

        def reset_for_new_testable(output_directory)
          reset_reportnamer
          reset_interstitial(output_directory)
        end

        def correcting_scan(scan_run_options, batch, reportnamer)
          scan_options = @scan_options.merge(scan_run_options)
          try_count = 0
          tests_passed = true
          begin
            try_count += 1
            config = FastlaneCore::Configuration.create(
              Fastlane::Actions::ScanAction.available_options,
              scan_options.merge(reportnamer.scan_options)
            )
            Fastlane::Actions::ScanAction.run(config)
            @interstitial.finish_try(try_count)
            tests_passed = true
          rescue FastlaneCore::Interface::FastlaneTestFailure => e
            FastlaneCore::UI.verbose("Scan failed with #{e}")
            if try_count < @try_count
              @retry_total_count += 1
              scan_options.delete(:code_coverage)
              tests_to_retry = failed_tests(reportnamer, scan_options[:output_directory]).map(&:shellescape)

              scan_options[:only_testing] = tests_to_retry
              FastlaneCore::UI.message('Re-running scan on only failed tests')
              @interstitial.finish_try(try_count)
              retry
            end
            tests_passed = false
          end
          tests_passed
        end

        def failed_tests(reportnamer, output_directory)
          report_filepath = File.join(output_directory, reportnamer.junit_last_reportname)
          config = FastlaneCore::Configuration.create(
            Fastlane::Actions::TestsFromJunitAction.available_options,
            {
              junit: File.absolute_path(report_filepath)
            }
          )
          Fastlane::Actions::TestsFromJunitAction.run(config)[:failed]
        end
      end
    end
  end
end