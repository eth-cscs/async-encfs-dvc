ml_tutorial_dvc_repo:
	mkdir -p examples/data_test/v0

ml_tutorial_nbconvert:
	cd examples && \
		cp ml_tutorial.ipynb test_ml_tutorial.ipynb && \
		sed '/get_ipython/d;s/data\/v0/examples\/data_test\/v0/g;/# test_ml_tutorial: skip/d' test_ml_tutorial.ipynb >test_ml_tutorial.tmp && \
		mv test_ml_tutorial.tmp test_ml_tutorial.ipynb

ml_tutorial_prepare: ml_tutorial_nbconvert ml_tutorial_dvc_repo

encfs_sim_tutorial_dvc_repo:
	mkdir -p examples/data_test/v1

encfs_sim_tutorial_nbconvert:
	cd examples && \
		cp encfs_sim_tutorial.ipynb test_encfs_sim_tutorial.ipynb && \
		sed '/get_ipython/d;s/data\/v1/examples\/data_test\/v1/g;/# test_encfs_sim_tutorial: skip/d' test_encfs_sim_tutorial.ipynb >test_encfs_sim_tutorial.tmp && \
		mv test_encfs_sim_tutorial.tmp test_encfs_sim_tutorial.ipynb

encfs_sim_tutorial_prepare: encfs_sim_tutorial_nbconvert encfs_sim_tutorial_dvc_repo

slurm_async_sim_tutorial_dvc_repo:
	mkdir -p examples/data_test/v2

slurm_async_sim_tutorial_nbconvert:
	cd examples && \
		cp slurm_async_sim_tutorial.ipynb test_slurm_async_sim_tutorial.ipynb && \
		sed '/get_ipython/d;s/data\/v2/examples\/data_test\/v2/g;/# test_slurm_async_sim_tutorial: skip/d' test_slurm_async_sim_tutorial.ipynb >test_slurm_async_sim_tutorial.tmp && \
		mv test_slurm_async_sim_tutorial.tmp test_slurm_async_sim_tutorial.ipynb

slurm_async_sim_tutorial_prepare: slurm_async_sim_tutorial_nbconvert slurm_async_sim_tutorial_dvc_repo


vit_example_dvc_repo:
	mkdir -p examples/data_test/v3

vit_example_nbconvert:
	cd examples && \
		cp vit_example.ipynb test_vit_example.ipynb && \
		sed '/get_ipython/d;s/data\/v3/examples\/data_test\/v3/g;/# test_vit_example: skip/d' test_vit_example.ipynb >test_vit_example.tmp && \
		mv test_vit_example.tmp test_vit_example.ipynb

vit_example_prepare: vit_example_nbconvert vit_example_dvc_repo


benchmark_plain_prepare_dvc_repo:
	mkdir -p examples/data_test/benchmark_plain && \
		cd examples/data_test/benchmark_plain && \
		dvc_init_repo . plain

benchmark_encfs_prepare_dvc_repo:
	mkdir -p examples/data_test/benchmark_encfs && \
		cd examples/data_test/benchmark_encfs && \
		dvc_init_repo . encfs && \
		echo 1234 > encfs_tutorial.key && \
		cp ../../.encfs6.xml.tutorial encrypt/ && \
		mv encrypt/.encfs6.xml.tutorial encrypt/.encfs6.xml

benchmarks_prepare_code:
	mkdir -p examples/data_test/ && \
		cp -r benchmarks examples/data_test/ && \
		cd examples/data_test/benchmarks && \
		sed 's/10\*\*9/10\*\*6/g;s/output_files_per_rank=1000 ;;/output_files_per_rank=3 ;;/g' iterative_sim_benchmark.sh >iterative_sim_benchmark.tmp && \
		mv iterative_sim_benchmark.tmp iterative_sim_benchmark.sh && \
		chmod u+x iterative_sim_benchmark.sh

clean:
	rm -f examples/test_ml_tutorial.ipynb \
		examples/test_ml_tutorial_papermill.ipynb
	rm -f examples/test_encfs_sim_tutorial.ipynb \
		examples/test_encfs_sim_tutorial_papermill.ipynb
	rm -f examples/test_slurm_async_sim_tutorial.ipynb \
		examples/test_slurm_async_sim_tutorial_papermill.ipynb
	rm -f examples/test_vit_example.ipynb \
		examples/test_vit_example_papermill.ipynb
	git rm -rf --ignore-unmatch \
		examples/data_test/v0/.dvc* \
		examples/data_test/v1/.dvc* \
		examples/data_test/v2/.dvc* \
		examples/data_test/v3/.dvc* \
		examples/data_test/benchmark_plain/.dvc* \
		examples/data_test/benchmark_encfs/.dvc*
	rm -rf examples/data_test
