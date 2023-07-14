ml_tutorial_dvc_repo:
	mkdir -p examples/data_test/v0

ml_tutorial_prepare_app_policies:
	cd examples && \
		cd app_prep && \
		cp dvc_app.yaml dvc_app_test.yaml && \
		sed 's/data\/v0/data_test\/v0/g' dvc_app_test.yaml >dvc_app_test.tmp  && \
		mv dvc_app_test.tmp dvc_app_test.yaml && \
		cd ../app_ml && \
		cp dvc_app.yaml dvc_app_test.yaml && \
		sed 's/data\/v0/data_test\/v0/g' dvc_app_test.yaml >dvc_app_test.tmp  && \
		mv dvc_app_test.tmp dvc_app_test.yaml

ml_tutorial_nbconvert:
	cd examples && \
		cp ml_tutorial.ipynb test_ml_tutorial.ipynb && \
		sed '/get_ipython/d;s/data\/v0/examples\/data_test\/v0/g;s/dvc_app.yaml/dvc_app_test.yaml/g;/# test_ml_tutorial: skip/d' test_ml_tutorial.ipynb >test_ml_tutorial.tmp && \
		mv test_ml_tutorial.tmp test_ml_tutorial.ipynb

ml_tutorial_prepare: ml_tutorial_nbconvert ml_tutorial_prepare_app_policies ml_tutorial_dvc_repo

clean:
	rm -f examples/test_ml_tutorial.ipynb examples/test_ml_tutorial_papermill.ipynb
	rm -f examples/app_prep/dvc_app_test.yaml examples/app_ml/dvc_app_test.yaml
	rm -rf examples/data_test
